// package provides a very simple (for now) HTTP/1.1 client.
package client

import "core:bufio"
import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:net"
import "core:c"
import "core:strings"
import "core:log"
import "core:strconv"

import http ".."
import openssl "../openssl"

Request :: struct {
	method:  http.Method,
	headers: http.Headers,
	cookies: [dynamic]http.Cookie,
	body:    bytes.Buffer,
}

// Initializes the request with sane defaults using the given allocator.
request_init :: proc(r: ^Request, method := http.Method.Get, allocator := context.allocator) {
	r.method = method
	r.headers = make(http.Headers, 3, allocator)
	r.cookies = make([dynamic]http.Cookie, allocator)
	bytes.buffer_init_allocator(&r.body, 0, 0, allocator)
}

// Destroys the request.
// Header keys and values that the user added will have to be deleted by the user.
// Same with any strings inside the cookies.
request_destroy :: proc(r: ^Request) {
	delete(r.headers)
	delete(r.cookies)
	bytes.buffer_destroy(&r.body)
}

with_json :: proc(r: ^Request, v: any, opt: json.Marshal_Options = {}) -> json.Marshal_Error {
	r.method = .Post
	r.headers["content-type"] = http.mime_to_content_type(.Json)

	stream := bytes.buffer_to_stream(&r.body)
	opt := opt
	json.marshal_to_writer(io.to_writer(stream), v, &opt) or_return
	return nil
}

get :: proc(target: string, allocator := context.allocator) -> (Response, Error) {
	r: Request
	request_init(&r, .Get, allocator)
	defer request_destroy(&r)

	return request(target, &r, allocator)
}

Request_Error :: enum {
	Invalid_Response_HTTP_Version,
	Invalid_Response_Method,
	Invalid_Response_Header,
	Invalid_Response_Cookie,
}

SSL_Error :: enum {
	Controlled_Shutdown,
	Fatal_Shutdown,
	SSL_Write_Failed,
}

Error :: union {
	net.Dial_Error,
	net.Parse_Endpoint_Error,
	net.Network_Error,
	bufio.Scanner_Error,
	Request_Error,
	SSL_Error,
}

request :: proc(target: string, request: ^Request, allocator := context.allocator) -> (res: Response, err: Error) {
	url, endpoint := parse_endpoint(target) or_return
	defer delete(url.queries)

	// NOTE: we don't support persistent connections yet.
	request.headers["connection"] = "close"

	req_buf := format_request(url, request, allocator)
	defer bytes.buffer_destroy(&req_buf)

	socket := net.dial_tcp(endpoint) or_return

	// HTTPS using openssl.
	if url.scheme == "https" {
		using openssl

		ctx := SSL_CTX_new(TLS_client_method())
		ssl := SSL_new(ctx)
		SSL_set_fd(ssl, c.int(socket))

		switch SSL_connect(ssl) {
		case 2:
			err = SSL_Error.Controlled_Shutdown
			return
		case 1: // success
		case:
			err = SSL_Error.Fatal_Shutdown
			return
		}

		buf := bytes.buffer_to_bytes(&req_buf)
		to_write := len(buf)
		for to_write > 0 {
			ret := SSL_write(ssl, raw_data(buf), c.int(to_write))
			if ret <= 0 {
				err = SSL_Error.SSL_Write_Failed
				return
			}

			to_write -= int(ret)
		}

		return parse_response(SSL_Communication{
			ssl    = ssl,
			ctx    = ctx,
			socket = socket,
		}, allocator)
	}

	// HTTP, just send the request.
	net.send_tcp(socket, bytes.buffer_to_bytes(&req_buf)) or_return
	return parse_response(socket, allocator)
}

Response :: struct {
	status:    http.Status,
	// headers and cookies should be considered read-only, after a response is returned.
	headers:   http.Headers,
	cookies:   [dynamic]http.Cookie,
	_socket:   Communication,
	_body:     bufio.Scanner,
	_body_err: http.Body_Error,
}

// Frees the response, closes the connection.
// Optionally pass the response_body returned 'body' and 'was_allocation' to destroy it too.
response_destroy :: proc(res: ^Response, body: Maybe(http.Body_Type) = nil, was_allocation := false) {
	// Header keys are allocated, values are slices into the body.
	for k in res.headers {
		delete(k)
	}
	delete(res.headers)

	bufio.scanner_destroy(&res._body)

	// Cookies only contain slices to memory inside the scanner body.
	// So just deleting the array will be enough.
	delete(res.cookies)

	if body != nil {
		body_destroy(body.(http.Body_Type), was_allocation)
	}

	// We close now and not at the time we got the response because reading the body,
	// could make more reads need to happen (like with chunked encoding).
	switch comm in res._socket {
	case net.TCP_Socket:
		net.close(comm)
	case SSL_Communication:
		openssl.SSL_free(comm.ssl)
		openssl.SSL_CTX_free(comm.ctx)
		net.close(comm.socket)
	}
}

body_destroy :: http.body_destroy

// Retrieves the response's body, can only be called once.
// Free the returned body using body_destroy().
response_body :: proc(res: ^Response, max_length := -1, allocator := context.allocator) -> (body: http.Body_Type, was_allocation: bool, err: http.Body_Error) {
	defer res._body_err = err
	assert(res._body_err == nil)
    body, was_allocation, err = parse_body(&res.headers, &res._body, max_length, allocator)
	return
}

// TODO: Body parsing is pretty much a duplicate of the http, just not non-blocking.
// This needs serious refactoring.

// Meant for internal use, you should use `client.response_body`.
parse_body :: proc(headers: ^http.Headers, _body: ^bufio.Scanner, max_length := -1, allocator := context.allocator) -> (body: http.Body_Type, was_allocation: bool, err: http.Body_Error) {
	if enc_header, ok := headers["transfer-encoding"]; ok && strings.has_suffix(enc_header, "chunked") {
        was_allocation = true
		body = response_body_chunked(headers, _body, max_length, allocator) or_return
	} else {
		body = response_body_length(headers, _body, max_length) or_return
	}

	// Automatically decode url encoded bodies.
	if typ, ok := headers["content-type"]; ok && typ == "application/x-www-form-urlencoded" {
		plain := body.(http.Body_Plain)
        defer if was_allocation do delete(plain)

		keyvalues := strings.split(plain, "&", allocator)
        defer delete(keyvalues, allocator)

		queries := make(http.Body_Url_Encoded, len(keyvalues), allocator)
		for keyvalue in keyvalues {
			seperator := strings.index(keyvalue, "=")
			if seperator == -1 { 	// The keyvalue has no value.
				queries[keyvalue] = ""
				continue
			}

            key, key_decoded_ok := net.percent_decode(keyvalue[:seperator], allocator)
            if !key_decoded_ok {
                log.warnf("url encoded body key %q could not be decoded", keyvalue[:seperator])
                continue
            }

			val, val_decoded_ok := net.percent_decode(keyvalue[seperator + 1:], allocator)
            if !val_decoded_ok {
                log.warnf("url encoded body value %q for key %q could not be decoded", keyvalue[seperator+1:], key)
                continue
            }

			queries[key] = val
		}

		body = queries
	}

	return
}

// "Decodes" a response body based on the content length header.
// Meant for internal usage, you should use `client.response_body`.
response_body_length :: proc(headers: ^http.Headers, _body: ^bufio.Scanner, max_length: int) -> (string, http.Body_Error) {
	len, ok := headers["content-length"]
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

	_body.max_token_size = ilen
	defer _body.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

	_body.split = scan_num_bytes
	defer _body.split = bufio.scan_lines

	log.debugf("scanning %i bytes body", ilen)

	if !bufio.scanner_scan(_body) {
		return "", .Scan_Failed
	}

	return bufio.scanner_text(_body), .None
}

// "Decodes" a chunked transfer encoded request body.
// Meant for internal usage, you should use `client.response_body`.
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
response_body_chunked :: proc(headers: ^http.Headers, _body: ^bufio.Scanner, max_length: int, allocator := context.allocator) -> (body: string, err: http.Body_Error) {
	body_buff: bytes.Buffer

	bytes.buffer_init_allocator(&body_buff, 0, 0, allocator)
    defer if err != nil do bytes.buffer_destroy(&body_buff)

	for {
		if !bufio.scanner_scan(_body) {
			return "", .Scan_Failed
		}

		size_line := bufio.scanner_bytes(_body)

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := bytes.index_byte(size_line, ';'); semi > -1 {
			size_line = size_line[:semi]
		}

		size, ok := strconv.parse_int(string(size_line), 16)
        if !ok {
            err = .Invalid_Chunk_Size
            return
        }
		if size == 0 do break

		if max_length > -1 && bytes.buffer_length(&body_buff) + size > max_length {
			return "", .Too_Long
		}

		// user_index is used to set the amount of bytes to scan in scan_num_bytes.
		context.user_index = size

		_body.max_token_size = size
		_body.split = scan_num_bytes

		if !bufio.scanner_scan(_body) {
			return "", .Scan_Failed
		}

		_body.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		_body.split = bufio.scan_lines

		bytes.buffer_write(&body_buff, bufio.scanner_bytes(_body))

        // Read empty line after chunk.
        if !bufio.scanner_scan(_body) {
            return "", .Scan_Failed
        }
        assert(bufio.scanner_text(_body) == "")
	}

	// Read trailing empty line (after body, before trailing headers).
	if !bufio.scanner_scan(_body) || bufio.scanner_text(_body) != "" {
		return "", .Scan_Failed
	}

	// Keep parsing the request as line delimited headers until we get to an empty line.
	for {
        // If there are no trailing headers, this case is hit.
		if !bufio.scanner_scan(_body) {
            break
		}

		line := bufio.scanner_text(_body)

		// The first empty line denotes the end of the headers section.
		if line == "" {
			break
		}

		key, ok := http.header_parse(headers, line)
		if !ok {
			return "", .Invalid_Trailer_Header
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if !http.header_allowed_trailer(key) {
			delete(headers[key])
			delete_key(headers, key)
		}
	}

	if "trailer" in headers {
		delete(headers["trailer"])
		delete_key(headers, "trailer")
	}

	headers["transfer-encoding"] = strings.trim_suffix(headers["transfer-encoding"], "chunked")

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
        return
	}

	return n, data[:n], nil, false
}
