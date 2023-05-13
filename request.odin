package http

import "core:bufio"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:fmt"
import "core:bytes"
import "core:log"
import "core:net"

Request :: struct {
	// If in a handler, this is always there and never None.
	line:       Maybe(Requestline),
	headers:    Headers,
	url:        URL,
	client:     net.Endpoint,

	// Route params/captures.
	url_params: []string,

	// Allocator that is freed after the request.
	allocator:  mem.Allocator,
	_body:      bufio.Scanner,
	_body_err:  Body_Error,
}

request_init :: proc(r: ^Request, allocator: mem.Allocator = context.allocator) {
	r.headers = make(Headers, 3, allocator)
	r.allocator = allocator
}

headers_validate :: proc(using r: Request) -> bool {
	// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
	// HTTP/1.1 request message that lacks a Host header field.
	("Host" in headers) or_return

	// RFC 7230 3.3.3: If a Transfer-Encoding header field
	// is present in a request and the chunked transfer coding is not
	// the final encoding, the message body length cannot be determined
	// reliably; the server MUST respond with the 400 (Bad Request)
	// status code and then close the connection.
	if enc_header, ok := headers["Transfer-Encoding"]; ok {
		strings.has_suffix(enc_header, "chunked") or_return
	}

	// RFC 7230 3.3.3: If a message is received with both a Transfer-Encoding and a
	// Content-Length header field, the Transfer-Encoding overrides the
	// Content-Length.  Such a message might indicate an attempt to
	// perform request smuggling (Section 9.5) or response splitting
	// (Section 9.4) and ought to be handled as an error.
	if "Transfer-Encoding" in headers && "Content-Length" in headers {
		delete(headers["Content-Length"])
		hdrs := headers
		delete_key(&hdrs, "Content-Length")
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

Body_Plain :: string
Body_Url_Encoded :: map[string]string

Body_Type :: union {
	Body_Plain,
	Body_Url_Encoded,
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(e: Body_Error) -> Status {
	switch e {
	case .Too_Long:                             return .Payload_Too_Large
	case .Scan_Failed, .Invalid_Trailer_Header: return .Bad_Request
	case .Invalid_Length, .Invalid_Chunk_Size:  return .Unprocessable_Content
	case .No_Length:                            return .Length_Required
	case .None:                                 return .Ok
	case:                                       return .Ok
	}
}

// Retrieves the request's body, can only be called once.
request_body :: proc(req: ^Request, max_length: int = -1) -> (body: Body_Type, err: Body_Error) {
	defer req._body_err = err

	assert(req._body_err == nil)

	if enc_header, ok := req.headers["Transfer-Encoding"]; ok && strings.has_suffix(enc_header, "chunked") {
		body = request_body_chunked(req, max_length) or_return
	} else {
		body = request_body_length(req, max_length) or_return
	}

	// Automatically decode url encoded bodies.
	if typ, ok := req.headers["Content-Type"]; ok && typ == "application/x-www-form-urlencoded" {
		plain := body.(Body_Plain)

		keyvalues := strings.split(plain, "&", req.allocator)
		queries := make(Body_Url_Encoded, len(keyvalues), req.allocator)
		for keyvalue in keyvalues {
			seperator := strings.index(keyvalue, "=")
			if seperator == -1 { 	// The keyvalue has no value.
				queries[keyvalue] = ""
				continue
			}

			val, decoded_ok := net.percent_decode(keyvalue[seperator + 1:], req.allocator)
			queries[keyvalue[:seperator]] = decoded_ok ? val : keyvalue[seperator + 1:]
		}

		body = queries
	}

	return
}

// "Decodes" a request body based on the content length header.
@(private)
request_body_length :: proc(req: ^Request, max_length: int) -> (string, Body_Error) {
	len, ok := req.headers["Content-Length"]
	if !ok {
		return "", .No_Length
	}

	ilen, lenok := strconv.parse_int(len, 10)
	if !lenok {
		return "", .Invalid_Length
	}

	if max_length > -1 && ilen > max_length {
		return "", .Too_Long
	}

	if ilen == 0 {
		return "", nil
	}

	// user_index is used to set the amount of bytes to scan in scan_num_bytes.
	context.user_index = ilen

	req._body.max_token_size = ilen
	defer req._body.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

	req._body.split = scan_num_bytes
	defer req._body.split = bufio.scan_lines

	log.infof("scanning %i bytes body", ilen)

	if !bufio.scanner_scan(&req._body) {
		return "", .Scan_Failed
	}

	return bufio.scanner_text(&req._body), .None
}

// "Decodes" a chunked transfer encoded request body.
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
@(private)
request_body_chunked :: proc(req: ^Request, max_length: int) -> (body: string, err: Body_Error) {
	body_buff: bytes.Buffer
	// Needs to be 1 cap because 0 would not use the allocator provided.
	bytes.buffer_init_allocator(&body_buff, 0, 1, req.allocator)
	for {
		if !bufio.scanner_scan(&req._body) {
			return "", .Scan_Failed
		}

		size_line := bufio.scanner_text(&req._body)

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := strings.index(size_line, ";"); semi > -1 {
			size_line = size_line[:semi]
		}

		size := hex_decode_size(size_line) or_return
		if size == 0 do break

		if max_length > -1 && bytes.buffer_length(&body_buff) + size > max_length {
			return "", .Too_Long
		}

		// user_index is used to set the amount of bytes to scan in scan_num_bytes.
		context.user_index = size

		req._body.max_token_size = size
		defer req._body.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		req._body.split = scan_num_bytes
		defer req._body.split = bufio.scan_lines

		if !bufio.scanner_scan(&req._body) {
			return "", .Scan_Failed
		}

		bytes.buffer_write(&body_buff, bufio.scanner_bytes(&req._body))
	}

	// Read trailing empty line (after body, before trailing headers).
	if !bufio.scanner_scan(&req._body) || bufio.scanner_text(&req._body) != "" {
		return "", .Scan_Failed
	}

	// Keep parsing the request as line delimited headers until we get to an empty line.
	for {
		if !bufio.scanner_scan(&req._body) {
			return "", .Scan_Failed
		}

		line := bufio.scanner_text(&req._body)

		// The first empty line denotes the end of the headers section.
		if line == "" {
			break
		}

		key, ok := header_parse(&req.headers, line)
		if !ok {
			return "", .Invalid_Trailer_Header
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if !header_allowed_trailer(key) {
			delete(req.headers[key])
			delete_key(&req.headers, key)
		}
	}

	req.headers["Content-Length"] = fmt.tprintf("%i", bytes.buffer_length(&body_buff))

	if "Trailer" in req.headers {
		delete(req.headers["Trailer"])
		delete_key(&req.headers, "Trailer")
	}

	req.headers["Transfer-Encoding"] = strings.trim_suffix(req.headers["Transfer-Encoding"], "chunked")

	return bytes.buffer_to_string(&body_buff), .None
}

// A scanner bufio.Split_Proc implementation to scan a given amount of bytes.
// The amount of bytes should be set in the context.user_index.
@(private)
scan_num_bytes :: proc(data: []byte, at_eof: bool) -> (
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
		return 0, data, nil, false
	}

	return n, data[:n], nil, true
}

// This is equivalent to around 4GB, I think that is a sane max.
@(private)
HEX_SIZE_MAX :: len("FFFFFFFF")

@(private)
hex_decode_size :: proc(str: string) -> (int, Body_Error) {
	str := str
	str = strings.trim_prefix(str, "0x")

	if len(str) > HEX_SIZE_MAX {
		return 0, .Too_Long
	}

	val: int
	for c, i in str {
		index := (len(str) - 1) - i // reverse the loop.

		hd, ok := hex_digit(u8(c))
		if !ok {
			return 0, .Invalid_Chunk_Size
		}

		val += int(hd) << uint(4 * index)
	}

	return val, nil
}

@(private)
hex_digit :: proc(char: byte) -> (u8, bool) {
    switch char {
    case '0' ..= '9': return char - '0', true
    case 'a' ..= 'f': return char - 'a' + 10, true
    case 'A' ..= 'F': return char - 'A' + 10, true
    case:             return 0, false
    }
}
