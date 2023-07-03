package http

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "nbio"

Response :: struct {
	status:  Status,
	headers: Headers,
	cookies: [dynamic]Cookie,
	body:    bytes.Buffer,
	send:    proc(),
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
response_send :: proc(using r: ^Response, conn: ^Connection, allocator := context.allocator) {
	res: bytes.Buffer
	// Responses are on average at least 100 bytes, so lets start there, but add the body's length.
	initial_buf_cap := response_needs_content_length(r, conn) ? 100 + bytes.buffer_length(&body) : 100
	bytes.buffer_init_allocator(&res, 0, initial_buf_cap, allocator)

	will_close := response_must_close(conn.curr_req, r)

	// RFC 7230 6.3: A server MUST read
	// the entire request message body or close the connection after sending
	// its response, since otherwise the remaining data on a persistent
	// connection would be misinterpreted as the next request.
	if !will_close {
		if conn.curr_req._body == nil {
			// No error means the body was not read by a handler.
			log.debug("reading body")
			request_body(conn.curr_req, Max_Post_Handler_Discard_Bytes)
		}

		if err, is_err := conn.curr_req._body.(Body_Error); is_err {
			switch err {
			case .Scan_Failed, .Invalid_Length, .Invalid_Trailer_Header, .Too_Long, .Invalid_Chunk_Size:
				// Any read error should close the connection.
				status = body_error_status(err)
				headers["connection"] = "close"
				will_close = true
			case .No_Length, .None: // no-op, request had no body or read succeeded.
			case:
				assert(err != nil, "always expect error from request_body")
			}
		}
	}

	bytes.buffer_write_string(&res, "HTTP/1.1 ")
	bytes.buffer_write_string(&res, status_string(status))
	bytes.buffer_write_string(&res, "\r\n")

	// Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
	if status >= .Ok && status <= .Internal_Server_Error && "date" not_in headers {
		headers["date"] = format_date_header(time.now(), allocator)
	}

	// Write the status code as the body, if there is no body set by the handlers.
	if response_can_have_body(r, conn) && !status_success(status) && bytes.buffer_length(&body) == 0 {
		bytes.buffer_write_string(&body, status_string(status))
		headers["content-type"] = mime_to_content_type(.Plain)
	}

	if "content-length" not_in headers && response_needs_content_length(r, conn) {
		buf := make([]byte, 32, allocator)
		headers["content-length"] = strconv.itoa(buf, bytes.buffer_length(&body))
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

	// Empty line denotes end of headers and start of body.
	bytes.buffer_write_string(&res, "\r\n")

	if response_can_have_body(r, conn) do bytes.buffer_write(&res, bytes.buffer_to_bytes(&body))

	buf := bytes.buffer_to_bytes(&res)
	conn.response = Response_Inflight{buf = buf, will_close = will_close}
	nbio.send(
		&conn.server.io,
		nbio.Op_Send{os.Socket(conn.socket), buf, 0},
		conn,
		on_response_sent,
	)
}

@(private)
on_response_sent :: proc(conn_: rawptr, sent: u32, err: os.Errno) {
	conn := cast(^Connection)conn_
	res := conn.response.(Response_Inflight)

	res.sent += int(sent)
	if len(res.buf) != int(sent) {
		nbio.send(
			&conn.server.io,
			nbio.Op_Send{os.Socket(conn.socket), res.buf[res.sent:], 0},
			conn,
			on_response_sent,
		)
		return
	}

	defer free_all(conn.curr_req.allocator)
	defer conn.response = nil

	switch {
	case err != os.ERROR_NONE:
		log.errorf("could not send response: %v", err)
		fallthrough
	case res.will_close:
		conn.state = .Closing
		connection_close(conn)
	case:
		conn.state = .Idle
		conn_handle_req(conn)
	}
}

// Sets the response to one that sends the given HTML.
respond_html :: proc(using r: ^Response, html: string) {
	status = .Ok
	bytes.buffer_write_string(&body, html)
	headers["content-type"] = mime_to_content_type(Mime_Type.Html)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(using r: ^Response, text: string) {
	status = .Ok
	bytes.buffer_write_string(&body, text)
	headers["content-type"] = mime_to_content_type(Mime_Type.Plain)
}

// Sets the response to one that sends the contents of the file at the given path.
// Content-Type header is set based on the file extension, see the MimeType enum for known file extensions.
respond_file :: proc(using r: ^Response, path: string, allocator := context.allocator) {
	bs, ok := os.read_entire_file(path, allocator)
	if !ok {
		status = .NotFound
		return
	}

	respond_file_content(r, path, bs)
}

respond_file_content :: proc(using r: ^Response, path: string, content: []byte) {
	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)

	status = .Ok
	headers["content-type"] = content_type
	bytes.buffer_write(&body, content)
}

// Sets the response to one that, based on the request path, returns a file.
// base:    The base of the request path that should be removed when retrieving the file.
// target:  The path to the directory to serve.
// request: The request path.
//
// Path traversal is detected and cleaned up.
// The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
respond_dir :: proc(using r: ^Response, base, target, request: string, allocator := context.allocator) {
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
respond_json :: proc(using r: ^Response, v: any, opt: json.Marshal_Options = {}) -> json.Marshal_Error {
	stream := bytes.buffer_to_stream(&r.body)
	opt := opt
	json.marshal_to_writer(io.to_writer(stream), v, &opt) or_return

	status = .Ok
	headers["content-type"] = mime_to_content_type(Mime_Type.Json)

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
cookie_string :: proc(using c: Cookie, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, 0, 20, allocator)

	strings.write_string(&b, "set-cookie: ")
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
	case .None:   strings.write_string(&b, "; SameSite=None")
	case .Lax:    strings.write_string(&b, "; SameSite=Lax")
	case .Strict: strings.write_string(&b, "; SameSite=Strict")
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

// TODO: check specific whitespace requirements in RFC.
//
// Allocations are done to check case-insensitive attributes but they are deleted right after.
// So, all the returned strings (inside cookie) are slices into the given value string.
cookie_parse :: proc(value: string, allocator := context.allocator) -> (cookie: Cookie, ok: bool) {
	value := value

	eq := strings.index_byte(value, '=')
	if eq < 1 do return

	cookie.name = value[:eq]
	value = value[eq+1:]

	semi := strings.index_byte(value, ';')
	switch semi {
	case -1:
		cookie.value = value
		ok = true
		return
	case 0: return
	case:
		cookie.value = value[:semi]
		value = value[semi+1:]
	}

	parse_part :: proc(cookie: ^Cookie, part: string, allocator := context.allocator) -> (ok: bool) {
		eq := strings.index_byte(part, '=')
		switch eq {
		case -1:
			key := strings.to_lower(part, allocator)
			defer delete(key)

			switch key {
			case "httponly":    cookie.http_only = true
			case "partitioned": cookie.partitioned = true
			case "secure":      cookie.secure = true
			case: return
			}
		case 0: return
		case:
			key := strings.to_lower(part[:eq], allocator)
			defer delete(key)

			value := part[eq+1:]

			switch key {
			case "domain":
				cookie.domain = value
			case "expires":
				cookie.expires_gmt = parse_date_header(value) or_return
			case "max-age":
				cookie.max_age_secs = strconv.parse_int(value, 10) or_return
			case "path":
				cookie.path = value
			case "samesite":
				val := strings.to_lower(value, allocator)
				defer delete(val)

				switch value {
				case "lax":    cookie.same_site = .Lax
				case "none":   cookie.same_site = .None
				case "strict": cookie.same_site = .Strict
				case: return
				}
			case: return
			}
		}
		return true
	}

	for semi := strings.index_byte(value, ';'); semi != -1; semi = strings.index_byte(value, ';') {
		part := strings.trim_left_space(value[:semi])
		value = value[semi+1:]
		parse_part(&cookie, part, allocator) or_return
	}

	part := strings.trim_left_space(value)
	if part == "" {
		ok = true
		return
	}

	parse_part(&cookie, part, allocator) or_return
	ok = true
	return
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
