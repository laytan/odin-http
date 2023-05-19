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
	bytes.buffer_init_allocator(&r.body, 0, 100, allocator)
}

with_json :: proc(r: ^Request, v: any, allocator := context.allocator, opt: json.Marshal_Options = {}) -> json.Marshal_Error {
	r.method = .Post
	r.headers["content-type"] = http.mime_to_content_type(.Json)

	stream := bytes.buffer_to_stream(&r.body)
	opt := opt
	json.marshal_to_writer(io.to_writer(stream), v, &opt) or_return
	return nil
}

get :: proc(target: string) -> (Response, Error) {
    req := Request{method = .Get}
	return request(target, &req)
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
	url, endpoint := parse_endpoint(target, allocator) or_return

	socket := net.dial_tcp(endpoint) or_return

	// NOTE: we don't support persistent connections yet.
	request.headers["connection"] = "close"

	req_buf := format_request(url, request, allocator)
	net.send_tcp(socket, bytes.buffer_to_bytes(&req_buf)) or_return

	return parse_response(socket, allocator)

}

Response :: struct {
	status:    http.Status,
	headers:   http.Headers,
	cookies:   [dynamic]http.Cookie,

	_socket:   net.TCP_Socket,
	_body:     bufio.Scanner,
	_body_err: http.Body_Error,
}

// Closes the request, this is automatically called if you call `response_body`.
// But if you don't, you can call this.
close :: proc(res: ^Response) {
	if res._socket == 0 do return
	net.close(res._socket)
	res._socket = 0
}

// Retrieves the response's body, can only be called once.
response_body :: proc(res: ^Response, max_length := -1, allocator := context.allocator) -> (body: http.Body_Type, err: http.Body_Error) {
	defer res._body_err = err
	assert(res._body_err == nil)
    body, err = http.parse_body(&res.headers, &res._body, max_length, allocator)
	close(res) // There is nothing left to do with the connection (everything is read), we can close.
	return
}
