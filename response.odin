package http

import "core:bytes"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:net"

import "nbio"

Response :: struct {
	status:  Status,
	headers: Headers,
	cookies: [dynamic]Cookie,
	body:    bytes.Buffer,
	_conn:   ^Connection,
}

response_init :: proc(r: ^Response, allocator := context.allocator) {
	r.status = .NotFound
	r.headers = make(Headers, 3, allocator)
	r.headers["server"] = "Odin"
	bytes.buffer_init_allocator(&r.body, 0, 0, allocator)
}

// Sends the response over the connection.
// Frees the allocator (should be a request scoped allocator).
// Closes the connection or starts the handling of the next request.
@(private)
response_send :: proc(using r: ^Response, conn: ^Connection, allocator := context.allocator) {
	context.allocator = allocator

	check_body := proc(body: Body_Type, was_alloc: bool, res: rawptr) {
		res := cast(^Response)res
		will_close: bool
		if err, is_err := body.(Body_Error); is_err {
			switch err {
			case .Scan_Failed, .Invalid_Length, .Invalid_Trailer_Header, .Too_Long, .Invalid_Chunk_Size:
				// Any read error should close the connection.
				res.status = body_error_status(err)
				res.headers["connection"] = "close"
				will_close = true
			case .No_Length, .None: // no-op, request had no body or read succeeded.
			case:
				assert(err != nil, "always expect error from request_body")
			}
		}

		response_send_got_body(res, will_close)
	}

	// RFC 7230 6.3: A server MUST read
	// the entire request message body or close the connection after sending
	// its response, since otherwise the remaining data on a persistent
	// connection would be misinterpreted as the next request.
	if !response_must_close(conn.curr_req, r) {
		request_body(conn.curr_req, check_body, Max_Post_Handler_Discard_Bytes, r)
	} else {
		response_send_got_body(r, true)
	}
}

@(private)
response_send_got_body :: proc(using r: ^Response, will_close: bool) {
	conn := r._conn

	res: bytes.Buffer
	// Responses are on average at least 100 bytes, so lets start there, but add the body's length.
	initial_buf_cap := response_needs_content_length(r, conn) ? 100 + bytes.buffer_length(&body) : 100
	bytes.buffer_init_allocator(&res, 0, initial_buf_cap)

	bytes.buffer_write_string(&res, "HTTP/1.1 ")
	bytes.buffer_write_string(&res, status_string(status))
	bytes.buffer_write_string(&res, "\r\n")

	// Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
	if status >= .Ok && status <= .Internal_Server_Error && "date" not_in headers {
		headers["date"] = format_date_header(time.now())
	}

	// Write the status code as the body, if there is no body set by the handlers.
	if response_can_have_body(r, conn) && !status_success(status) && bytes.buffer_length(&body) == 0 {
		bytes.buffer_write_string(&body, status_string(status))
		headers["content-type"] = mime_to_content_type(.Plain)
	}

	if "content-length" not_in headers && response_needs_content_length(r, conn) {
		buf := make([]byte, 32)
		headers["content-length"] = strconv.itoa(buf, bytes.buffer_length(&body))
	}

	for header, value in headers {
		bytes.buffer_write_string(&res, header)
		bytes.buffer_write_string(&res, ": ")

		// Escape newlines in headers, if we don't, an attacker can find an endpoint
		// that returns a header with user input, and inject headers into the response.
		// PERF: probably slow.
		esc_value, _ := strings.replace_all(value, "\n", "\\n")
		bytes.buffer_write_string(&res, esc_value)

		bytes.buffer_write_string(&res, "\r\n")
	}

	for cookie in cookies {
		bytes.buffer_write_string(&res, cookie_string(cookie))
		bytes.buffer_write_string(&res, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	bytes.buffer_write_string(&res, "\r\n")

	if response_can_have_body(r, conn) do bytes.buffer_write(&res, bytes.buffer_to_bytes(&body))

	buf := bytes.buffer_to_bytes(&res)
	conn.response = Response_Inflight {
		buf        = buf,
		will_close = will_close,
	}
	nbio.send(&conn.server.io, conn.socket, buf, conn, on_response_sent)
}


@(private)
on_response_sent :: proc(conn_: rawptr, sent: int, err: net.Network_Error) {
	conn := cast(^Connection)conn_
	res := conn.response.(Response_Inflight)

	res.sent += sent
	if len(res.buf) != res.sent {
		nbio.send(&conn.server.io, conn.socket, res.buf[res.sent:], conn, on_response_sent)
		return
	}

	if err != nil {
		log.errorf("could not send response: %v", err)
	}

	clean_request_loop(conn, res.will_close)
}

// Response has been sent, clean up and close/handle next.
@(private)
clean_request_loop :: proc(conn: ^Connection, close: bool = false) {
	free_all(conn.curr_req.allocator)
	conn.response = nil

	switch {
	case close:
		conn.state = .Closing
		connection_close(conn)
	case:
		conn.state = .Idle
		conn_handle_req(conn)
	}
}

// A server MUST NOT send a Content-Length header field in any response
// with a status code of 1xx (Informational) or 204 (No Content).  A
// server MUST NOT send a Content-Length header field in any 2xx
// (Successful) response to a CONNECT request.
@(private)
response_needs_content_length :: proc(r: ^Response, conn: ^Connection) -> bool {
	if status_informational(r.status) || r.status == .No_Content {
		return false
	}

	if rline, ok := conn.curr_req.line.(Requestline); ok {
		if status_success(r.status) && rline.method == .Connect {
			return false
		}

		return true
	}

	return true
}

@(private)
response_can_have_body :: proc(r: ^Response, conn: ^Connection) -> bool {
	response_needs_content_length(r, conn) or_return

	if rline, ok := conn.curr_req.line.(Requestline); ok {
		return rline.method != .Head
	}

	return true
}

// Determines if the connection needs to be closed after sending the response.
//
// If the request we are responding to indicates it is closing the connection, close our side too.
// If we are responding with a close connection header, make sure we close.
@(private)
response_must_close :: proc(req: ^Request, res: ^Response) -> bool {
	if req, req_has := req.headers["connection"]; req_has && req == "close" {
		return true
	} else if res, res_has := res.headers["connection"]; res_has && res == "close" {
		return true
	}

	return false
}
