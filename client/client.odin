// package provides a very simple (for now) HTTP/1.1 client.
package client

import "core:bufio"
import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:net"

import http ".."

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

Error :: union {
	net.Dial_Error,
	net.Parse_Endpoint_Error,
	net.Network_Error,
	bufio.Scanner_Error,
	Request_Error,
}

// TODO: max response-line and header lengths.
// TODO: think about memory.
request :: proc(target: string, request: ^Request, allocator := context.allocator) -> (res: Response, err: Error) {
	url, endpoint := parse_endpoint(target) or_return
	defer delete(url.queries)

	socket := net.dial_tcp(endpoint) or_return

	// NOTE: we don't support persistent connections yet.
	request.headers["connection"] = "close"

	req_buf := format_request(url, request, allocator)
	defer bytes.buffer_destroy(&req_buf)
	net.send_tcp(socket, bytes.buffer_to_bytes(&req_buf)) or_return

	return parse_response(socket, allocator)
}

Response :: struct {
	status:    http.Status,
	// headers and cookies should be considered read-only, after a response is returned.
	headers:   http.Headers,
	cookies:   [dynamic]http.Cookie,
	_socket:   net.TCP_Socket,
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
	net.close(res._socket)
}

body_destroy :: http.body_destroy

// Retrieves the response's body, can only be called once.
// Free the returned body using body_destroy().
response_body :: proc(res: ^Response, max_length := -1, allocator := context.allocator) -> (body: http.Body_Type, was_allocation: bool, err: http.Body_Error) {
	defer res._body_err = err
	assert(res._body_err == nil)
    body, was_allocation, err = http.parse_body(&res.headers, &res._body, max_length, allocator)
	return
}
