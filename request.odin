package http

import "core:net"
import "core:strings"

Request :: struct {
	// If in a handler, this is always there and never None.
	// TODO: we should not expose this as a maybe to package users.
	line:       Maybe(Requestline),

	// Is true if the request is actually a HEAD request,
	// line.method will be .Get if Server_Opts.redirect_head_to_get is set.
	is_head:    bool,

	headers:    Headers,
	url:        URL,
	client:     net.Endpoint,

	// Route params/captures.
	url_params: []string,

	// Internal usage only.
	_scanner:   ^Scanner,
	_body_ok:   Maybe(bool),
}

request_init :: proc(r: ^Request, allocator := context.allocator) {
	headers_init(&r.headers, allocator)
}

// TODO: call it headers_sanitize because it modifies the headers.

// Validates the headers of a request, from the pov of the server.
headers_validate_for_server :: proc(headers: ^Headers) -> bool {
	// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
	// HTTP/1.1 request message that lacks a Host header field.
	if !headers_has_unsafe(headers^, "host") {
		return false
	}

	return headers_validate(headers)
}

// Validates the headers, use `headers_validate_for_server` if these are request headers
// that should be validated from the server side.
headers_validate :: proc(headers: ^Headers) -> bool {
	// RFC 7230 3.3.3: If a Transfer-Encoding header field
	// is present in a request and the chunked transfer coding is not
	// the final encoding, the message body length cannot be determined
	// reliably; the server MUST respond with the 400 (Bad Request)
	// status code and then close the connection.
	if enc_header, ok := headers_get_unsafe(headers^, "transfer-encoding"); ok {
		strings.has_suffix(enc_header, "chunked") or_return
	}

	// RFC 7230 3.3.3: If a message is received with both a Transfer-Encoding and a
	// Content-Length header field, the Transfer-Encoding overrides the
	// Content-Length.  Such a message might indicate an attempt to
	// perform request smuggling (Section 9.5) or response splitting
	// (Section 9.4) and ought to be handled as an error.
	if headers_has_unsafe(headers^, "transfer-encoding") && headers_has_unsafe(headers^, "content-length") {
		headers_delete_unsafe(headers, "content-length")
	}

	return true
}
