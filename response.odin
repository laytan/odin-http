package http

import "core:bytes"
import "core:net"
import "core:mem"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:encoding/json"
import "core:time"

Response :: struct {
	status:  Status,
	headers: Headers,
	cookies: [dynamic]Cookie,
	body:    bytes.Buffer,
}

response_init :: proc(r: ^Response, s: net.TCP_Socket, allocator: mem.Allocator = context.allocator) {
	r.status = .NotFound
	r.headers = make(Headers, 3, allocator)
	r.headers["Server"] = "Odin"
	// NOTE: need to be at least 1 capacity so the given allocator gets used.
	// TODO: report bug in Odin.
	bytes.buffer_init_allocator(&r.body, 0, 1, allocator)
}

// Sends the response over the connection.
response_send :: proc(using r: ^Response, conn: ^Connection, allocator: mem.Allocator = context.allocator) -> net.Network_Error {
	res: bytes.Buffer
	// Responses are on average at least 100 bytes, so lets start there, but add the body's length.
	initial_buf_cap := response_needs_content_length(r, conn) ? 100 + bytes.buffer_length(&body) : 100
	bytes.buffer_init_allocator(&res, 0, initial_buf_cap, allocator)

	will_close := response_must_close(conn.curr_req, r)
	defer if will_close do connection_close(conn);

	// RFC 7230 6.3: A server MUST read
	// the entire request message body or close the connection after sending
	// its response, since otherwise the remaining data on a persistent
	// connection would be misinterpreted as the next request.
	if !will_close {
		switch conn.curr_req._body_err {
		case .Scan_Failed, .Invalid_Length, .Invalid_Chunk_Size, .Too_Long, .Invalid_Trailer_Header: // Any read error should close the connection.
			status = body_error_status(conn.curr_req._body_err)
			headers["Connection"] = "close"
			will_close = true
		case .No_Length, .None: // no-op, request had no body or read succeeded.
		case: // No error means the body was not read by a handler.
			_, err := request_body(conn.curr_req, Max_Post_Handler_Discard_Bytes)
			switch err {
			case .Scan_Failed, .Invalid_Length, .Invalid_Trailer_Header, .Too_Long, .Invalid_Chunk_Size: // Any read error should close the connection.
				status = body_error_status(conn.curr_req._body_err)
				headers["Connection"] = "close"
				will_close = true
			case .No_Length, .None: // no-op, request had no body or read succeeded.
			case: assert(err != nil, "always expect error from request_body")
			}
		}
	}

	bytes.buffer_write_string(&res, "HTTP/1.1 ")
	bytes.buffer_write_string(&res, status_string(status))
	bytes.buffer_write_string(&res, "\r\n")


    // Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
    if status >= .Ok && status <= .Internal_Server_Error && "Date" not_in headers {
        bytes.buffer_write_string(&res, "Date: ")
        bytes.buffer_write_string(&res, format_date_header(time.now(), allocator))
        bytes.buffer_write_string(&res, "\r\n")
    }

	for header, value in headers {
		bytes.buffer_write_string(&res, header)
		bytes.buffer_write_string(&res, ": ")

		// Escape newlines in headers, if we don't, an attacker can find an endpoint
		// that returns a header with user input, and inject headers into the response.
		esc_value, _ := strings.replace_all(value, "\n", "\\n", allocator)
		bytes.buffer_write_string(&res, esc_value)

		bytes.buffer_write_string(&res, "\r\n")
	}

	for cookie in cookies {
		bytes.buffer_write_string(&res, cookie_string(cookie))
		bytes.buffer_write_string(&res, "\r\n")
	}

	// Write the status code as the body, if there is no body set by the handlers.
	if response_can_have_body(r, conn) && !status_success(status) && bytes.buffer_length(&body) == 0 {
		bytes.buffer_write_string(&body, status_string(status))
	}

	if response_needs_content_length(r, conn) {
		bytes.buffer_write_string(&res, fmt.tprintf("Content-Length: %i", bytes.buffer_length(&body)))
		bytes.buffer_write_string(&res, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	bytes.buffer_write_string(&res, "\r\n")

	if response_can_have_body(r, conn) do bytes.buffer_write(&res, bytes.buffer_to_bytes(&body));

	_, err := net.send_tcp(conn.socket, bytes.buffer_to_bytes(&res))

	return err
}

// Sets the response to one that sends the given HTML.
respond_html :: proc(using r: ^Response, html: string) {
	status = .Ok
	bytes.buffer_write_string(&body, html)
	headers["Content-Type"] = mime_to_content_type(Mime_Type.Html)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(using r: ^Response, text: string) {
	status = .Ok
	bytes.buffer_write_string(&body, text)
	headers["Content-Type"] = mime_to_content_type(Mime_Type.Plain)
}

// Sets the response to one that sends the contents of the file at the given path.
// Content-Type header is set based on the file extension, see the MimeType enum for known file extensions.
respond_file :: proc(using r: ^Response, path: string, allocator: mem.Allocator = context.allocator) {
	bs, ok := os.read_entire_file(path, allocator)
	if !ok {
		status = .NotFound
		return
	}

	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)

	status = .Ok
	headers["Content-Type"] = content_type
	bytes.buffer_write(&body, bs)
}

// Sets the response to one that, based on the request path, returns a file.
// base:    The base of the request path that should be removed when retrieving the file.
// target:  The path to the directory to serve.
// request: The request path.
//
// Path traversal is detected and cleaned up.
// The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
respond_dir :: proc(using r: ^Response, base, target, request: string, allocator: mem.Allocator = context.allocator) {
	if !strings.has_prefix(request, base) {
		status = .NotFound
		return
	}

	// Detect path traversal attacks.
	req_clean := filepath.clean(request, allocator)
	base_clean := filepath.clean(base, allocator)
	if !strings.has_prefix(req_clean, base_clean) {
		status = .NotFound
		return
	}

	file_path := filepath.join([]string{"./", target, strings.trim_prefix(req_clean, base_clean)}, allocator)
	respond_file(r, file_path)
}

// Sets the response to one that returns the JSON representation of the given value.
respond_json :: proc(
	using r: ^Response,
	v: any,
	allocator: mem.Allocator = context.allocator,
	opt: json.Marshal_Options = {},
) -> json.Marshal_Error {
	bs := json.marshal(v, opt, allocator) or_return
	status = .Ok
	bytes.buffer_write(&body, bs)
	headers["Content-Type"] = mime_to_content_type(Mime_Type.Json)
	return nil
}

Same_Site :: enum {
	Unspecified,
	None,
	Strict,
	Lax,
}

Cookie :: struct {
	name:         string,
	value:        string,
	domain:       Maybe(string),
	expires_gmt:  Maybe(time.Time),
	http_only:    bool,
	max_age_secs: Maybe(int),
	partitioned:  bool,
	path:         Maybe(string),
	same_site:    Same_Site,
	secure:       bool,
}

// Builds the Set-Cookie header string representation of the given cookie.
cookie_string :: proc(using c: Cookie, allocator: mem.Allocator = context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, 0, 20, allocator)

	strings.write_string(&b, "Set-Cookie: ")
	strings.write_string(&b, name)
	strings.write_byte(&b, '=')
	strings.write_string(&b, value)

	if d, ok := domain.(string); ok {
		strings.write_string(&b, "; Domain=")
		strings.write_string(&b, d)
	}

	if e, ok := expires_gmt.(time.Time); ok {
		strings.write_string(&b, "; Expires=")
		strings.write_string(&b, format_date_header(e, allocator))
	}

	if a, ok := max_age_secs.(int); ok {
		strings.write_string(&b, "; Max-Age=")
		strings.write_int(&b, a)
	}

	if p, ok := path.(string); ok {
		strings.write_string(&b, "; Path=")
		strings.write_string(&b, p)
	}

	switch same_site {
	case .None:        strings.write_string(&b, "; SameSite=None")
	case .Lax:         strings.write_string(&b, "; SameSite=Lax")
	case .Strict:      strings.write_string(&b, "; SameSite=Strict")
	case .Unspecified: // no-op.
	}

	if secure {
		strings.write_string(&b, "; Secure")
	}

	if partitioned {
		strings.write_string(&b, "; Partitioned")
	}

	if http_only {
		strings.write_string(&b, "; HttpOnly")
	}

	return strings.to_string(b)
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
	if conn_header, ok := req.headers["Connection"]; ok && conn_header == "close" {
		return true
	} else if conn_header, ok := res.headers["Connection"]; ok && conn_header == "close" {
		return true
	}

	return false
}

