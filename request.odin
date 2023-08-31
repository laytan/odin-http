package http

import "core:bufio"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"

Request :: struct {
	// If in a handler, this is always there and never None.
	line:            Maybe(Requestline),
	// Is true if the request is actually a HEAD request,
	// line.method will be .Get if Server_Opts.redirect_head_to_get is set.
	is_head:         bool,
	headers:         Headers,
	url:             URL,
	client:          net.Endpoint,

	// Route params/captures.
	url_params:      []string,

	// A growing arena where allocations are freed after the response is sent.
	// PERF: we can remove this field, and use the context.temp_allocator.
	allocator:       mem.Allocator,

	// Body memoization and scanner.
	_scanner:        Scanner,
	_body:           Body_Type,
	_body_was_alloc: bool,
}

request_init :: proc(r: ^Request, allocator := context.allocator) {
	r.headers = make(Headers, 3, allocator)
	r.allocator = allocator
}

// Validates the headers of a request, from the pov of the server.
server_headers_validate :: proc(headers: ^Headers) -> bool {
	// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
	// HTTP/1.1 request message that lacks a Host header field.
	("host" in headers) or_return

	return headers_validate(headers)
}

// Validates the headers, use server_headers_validate if these are request headers,
// validated from the server side.
headers_validate :: proc(headers: ^Headers) -> bool {
	// RFC 7230 3.3.3: If a Transfer-Encoding header field
	// is present in a request and the chunked transfer coding is not
	// the final encoding, the message body length cannot be determined
	// reliably; the server MUST respond with the 400 (Bad Request)
	// status code and then close the connection.
	if enc_header, ok := headers["transfer-encoding"]; ok {
		strings.has_suffix(enc_header, "chunked") or_return
	}

	// RFC 7230 3.3.3: If a message is received with both a Transfer-Encoding and a
	// Content-Length header field, the Transfer-Encoding overrides the
	// Content-Length.  Such a message might indicate an attempt to
	// perform request smuggling (Section 9.5) or response splitting
	// (Section 9.4) and ought to be handled as an error.
	if "transfer-encoding" in headers && "content-length" in headers {
		delete(headers["content-length"])
		delete_key(headers, "content-length")
	}

	return true
}

Body_Error :: enum {
	None,
	No_Length,
	Invalid_Length,
	Too_Long,
	Scan_Failed,
	Invalid_Chunk_Size,
	Invalid_Trailer_Header,
}

// Any non-special body, could have been a chunked body that has been read in fully automatically.
// Depending on the return value for 'was_allocation' of the parse function, this is either an
// allocated string that you should delete or a slice into the body.
Body_Plain :: string

// A URL encoded body, map, keys and values are fully allocated on the allocator given to the parsing function,
// And should be deleted by you.
Body_Url_Encoded :: map[string]string

Body_Type :: union {
	Body_Plain,
	Body_Url_Encoded,
	Body_Error,
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(e: Body_Error) -> Status {
	switch e {
	case .Too_Long:
		return .Payload_Too_Large
	case .Scan_Failed, .Invalid_Trailer_Header:
		return .Bad_Request
	case .Invalid_Length, .Invalid_Chunk_Size:
		return .Unprocessable_Content
	case .No_Length:
		return .Length_Required
	case .None:
		return .OK
	case:
		return .OK
	}
}

// Frees the memory allocated by parsing the body.
// was_allocation is returned by the body parsing procedure.
body_destroy :: proc(body: Body_Type, was_allocation: bool) {
	switch b in body {
	case Body_Plain:
		if was_allocation do delete(b)
	case Body_Url_Encoded:
		for k, v in b {
			delete(k)
			delete(v)
		}
		delete(b)
	case Body_Error:
	}
}

// Retrieves the request's body, can only be called once.
// Free using body_destroy() if needed, the body automatically at the end of a request if this is a server request body.
// TODO: probably inefficient with all of the callbacks here.
request_body :: proc(
	req: ^Request,
	cb: proc(body: Body_Type, was_allocation: bool, user_data: rawptr),
	max_length: int = -1,
	user_data: rawptr = nil,
) {
	if req._body != nil {
		cb(req._body, req._body_was_alloc, user_data)
		return
	}

	Request_Body_State :: struct {
		cb:        proc(body: Body_Type, was_allocation: bool, user_data: rawptr),
		user_data: rawptr,
		req:       ^Request,
	}

	on_body :: proc(state: rawptr, body: Body_Type, was_allocation: bool) {
		state := cast(^Request_Body_State)state
		state.req._body = body
		state.req._body_was_alloc = was_allocation

		cb := state.cb
		ud := state.user_data
		free(state, state.req.allocator)

		cb(body, was_allocation, ud)
	}

	state := new(Request_Body_State, req.allocator)
	state.cb = cb
	state.user_data = user_data
	state.req = req

	parse_body(&req.headers, &req._scanner, max_length, state, on_body, req.allocator)
}

@(private)
Parsing_Body :: struct {
	allocator:        mem.Allocator,
	headers:          ^Headers,
	user_data:        rawptr,
	user_callback:    proc(user_data: rawptr, body: Body_Type, was_allocation: bool),
	parsing_callback: proc(parsing_body: ^Parsing_Body, body: string, was_allocation: bool, err: Body_Error),
	scanner:          ^Scanner,
	buf:              bytes.Buffer,
	max_length:       int,
}

// Meant for internal use, you should use `http.request_body`.
parse_body :: proc(
	headers: ^Headers,
	_body: ^Scanner,
	max_length := -1,
	user_data: rawptr,
	callback: proc(user_data: rawptr, body: Body_Type, was_allocation: bool),
	allocator := context.allocator,
) {
	on_body :: proc(pb: ^Parsing_Body, body: string, was_allocation: bool, err: Body_Error) {
		defer free(pb, pb.allocator)

		if err != nil {
			pb.user_callback(pb.user_data, err, false)
			return
		}

		// Automatically decode url encoded bodies.
		if typ, ok := pb.headers["content-type"]; ok && typ == "application/x-www-form-urlencoded" {
			plain := body
			defer if was_allocation do delete(plain)

			keyvalues := strings.split(plain, "&", pb.allocator)
			defer delete(keyvalues, pb.allocator)

			queries := make(Body_Url_Encoded, len(keyvalues), pb.allocator)
			for keyvalue in keyvalues {
				seperator := strings.index(keyvalue, "=")
				if seperator == -1 { 	// The keyvalue has no value.
					queries[keyvalue] = ""
					continue
				}

				key, key_decoded_ok := net.percent_decode(keyvalue[:seperator], pb.allocator)
				if !key_decoded_ok {
					log.warnf("url encoded body key %q could not be decoded", keyvalue[:seperator])
					continue
				}

				val, val_decoded_ok := net.percent_decode(keyvalue[seperator + 1:], pb.allocator)
				if !val_decoded_ok {
					log.warnf(
						"url encoded body value %q for key %q could not be decoded",
						keyvalue[seperator + 1:],
						key,
					)
					continue
				}

				queries[key] = val
			}

			pb.user_callback(pb.user_data, queries, was_allocation)
			return
		}

		pb.user_callback(pb.user_data, body, was_allocation)
	}

	pb := new(Parsing_Body, allocator)
	pb.parsing_callback = on_body
	pb.allocator = allocator
	pb.user_callback = callback
	pb.headers = headers
	pb.user_data = user_data
	pb.scanner = _body
	pb.max_length = max_length

	if enc_header, ok := headers["transfer-encoding"]; ok && strings.has_suffix(enc_header, "chunked") {
		request_body_chunked(pb, allocator)
	} else {
		request_body_length(pb)
	}
}

// "Decodes" a request body based on the content length header.
// Meant for internal usage, you should use `http.request_body`.
request_body_length :: proc(pb: ^Parsing_Body) {
	len, ok := pb.headers["content-length"]
	if !ok {
		pb.parsing_callback(pb, "", false, .No_Length)
		return
	}

	ilen, lenok := strconv.parse_int(len, 10)
	if !lenok {
		pb.parsing_callback(pb, "", false, .Invalid_Length)
		return
	}

	if pb.max_length > -1 && ilen > pb.max_length {
		pb.parsing_callback(pb, "", false, .Too_Long)
		return
	}

	if ilen == 0 {
		pb.parsing_callback(pb, "", false, nil)
		return
	}

	// user_index is used to set the amount of bytes to scan in scan_num_bytes.
	context.user_index = ilen

	pb.scanner.max_token_size = ilen
	defer pb.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

	pb.scanner.split = scan_num_bytes
	defer pb.scanner.split = bufio.scan_lines

	on_scan :: proc(pb: rawptr, body: []byte, err: bufio.Scanner_Error) {
		pb := cast(^Parsing_Body)pb
		if err != nil {
			pb.parsing_callback(pb, "", false, .Scan_Failed)
			return
		}

		pb.parsing_callback(pb, string(body), false, nil)
	}

	scanner_scan(pb.scanner, pb, on_scan)
}

// "Decodes" a chunked transfer encoded request body.
// Meant for internal usage, you should use `http.request_body`.
//
// RFC 7230 4.1.3 pseudo-code:
//
// length := 0
// read chunk-size, chunk-ext (if any), and CRLF
// while (chunk-size > 0) {
//    read chunk-data and CRLF
//    append chunk-data to decoded-body
//    length := length + chunk-size
//    read chunk-size, chunk-ext (if any), and CRLF
// }
// read trailer field
// while (trailer field is not empty) {
//    if (trailer field is allowed to be sent in a trailer) {
//    	append trailer field to existing header fields
//    }
//    read trailer-field
// }
// Content-Length := length
// Remove "chunked" from Transfer-Encoding
// Remove Trailer from existing header fields
request_body_chunked :: proc(pb: ^Parsing_Body, allocator := context.allocator) {
	on_scan :: proc(pb: rawptr, size_line: []byte, err: bufio.Scanner_Error) {
		pb := cast(^Parsing_Body)pb
		size_line := size_line

		if err != nil {
			bytes.buffer_destroy(&pb.buf)
			pb.parsing_callback(pb, "", false, .Scan_Failed)
			return
		}

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := bytes.index_byte(size_line, ';'); semi > -1 {
			size_line = size_line[:semi]
		}

		size, ok := strconv.parse_int(string(size_line), 16)
		if !ok {
			bytes.buffer_destroy(&pb.buf)
			pb.parsing_callback(pb, "", false, .Invalid_Chunk_Size)
			return
		}

		if size == 0 {
			on_scan_size_zero(pb)
			return
		}

		if pb.max_length > -1 && bytes.buffer_length(&pb.buf) + size > pb.max_length {
			bytes.buffer_destroy(&pb.buf)
			pb.parsing_callback(pb, "", false, .Too_Long)
			return
		}

		// user_index is used to set the amount of bytes to scan in scan_num_bytes.
		context.user_index = size

		pb.scanner.max_token_size = size
		pb.scanner.split = scan_num_bytes

		scanner_scan(pb.scanner, pb, on_scan_chunk)
	}

	on_scan_chunk :: proc(pb: rawptr, token: []byte, err: bufio.Scanner_Error) {
		pb := cast(^Parsing_Body)pb

		if err != nil {
			bytes.buffer_destroy(&pb.buf)
			pb.parsing_callback(pb, "", false, .Scan_Failed)
			return
		}

		pb.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		pb.scanner.split = bufio.scan_lines

		bytes.buffer_write(&pb.buf, token)

		on_scan_empty_line :: proc(pb: rawptr, token: []byte, err: bufio.Scanner_Error) {
			pb := cast(^Parsing_Body)pb

			if err != nil {
				bytes.buffer_destroy(&pb.buf)
				pb.parsing_callback(pb, "", false, .Scan_Failed)
				return
			}
			assert(len(token) == 0)

			scanner_scan(pb.scanner, pb, on_scan)
		}

		scanner_scan(pb.scanner, pb, on_scan_empty_line)
	}

	on_scan_size_zero :: proc(pb: ^Parsing_Body) {
		on_scan_empty_line :: proc(pb: rawptr, token: []byte, err: bufio.Scanner_Error) {
			pb := cast(^Parsing_Body)pb

			if err != nil {
				bytes.buffer_destroy(&pb.buf)
				pb.parsing_callback(pb, "", false, .Scan_Failed)
				return
			}
			assert(len(token) == 0)

			scanner_scan(pb.scanner, pb, on_scan)
		}

		scanner_scan(pb.scanner, pb, on_scan_trailer)
	}

	on_scan_trailer :: proc(pb: rawptr, line: []byte, err: bufio.Scanner_Error) {
		pb := cast(^Parsing_Body)pb

		if err != nil || len(line) == 0 {
			on_trailer_end(pb)
			return
		}

		key, ok := header_parse(pb.headers, string(line))
		if !ok {
			bytes.buffer_destroy(&pb.buf)
			pb.parsing_callback(pb, "", false, .Invalid_Trailer_Header)
			return
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if !header_allowed_trailer(key) {
			delete(pb.headers[key])
			delete_key(pb.headers, key)
		}

		scanner_scan(pb.scanner, pb, on_scan_trailer)
	}

	on_trailer_end :: proc(pb: ^Parsing_Body) {
		if "trailer" in pb.headers {
			delete(pb.headers["trailer"])
			delete_key(pb.headers, "trailer")
		}

		pb.headers["transfer-encoding"] = strings.trim_suffix(pb.headers["transfer-encoding"], "chunked")

		pb.parsing_callback(pb, bytes.buffer_to_string(&pb.buf), true, .None)
	}

	bytes.buffer_init_allocator(&pb.buf, 0, 0, allocator)
	scanner_scan(pb.scanner, pb, on_scan)
}

// A scanner bufio.Split_Proc implementation to scan a given amount of bytes.
// The amount of bytes should be set in the context.user_index.
@(private)
scan_num_bytes :: proc(
	data: []byte,
	at_eof: bool,
) -> (
	advance: int,
	token: []byte,
	err: bufio.Scanner_Error,
	final_token: bool,
) {
	n := context.user_index // Set context.user_index to the amount of bytes to read.
	if at_eof && len(data) < n {
		return
	}

	if len(data) < n {
		return
	}

	return n, data[:n], nil, false
}
