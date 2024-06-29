package http

import "core:strings"

// I want custom hash functions on maps :((((((

// PERF: could make a custom hash map that does a case-insensitive (ASCII) hash & compare.

// A case-insensitive ASCII map for storing headers.
Headers :: struct {
	_kv:      map[string]string,
	readonly: bool,
}

headers_init :: proc(h: ^Headers, allocator := context.allocator) {
	h._kv.allocator = allocator
}

headers_destroy :: proc(h: Headers) {
	delete(h._kv)
}

headers_count :: #force_inline proc(h: Headers) -> int {
	return len(h._kv)
}

/*
Sets a header, given key is first sanitized, final (sanitized) key is returned.
*/
headers_set :: proc(h: ^Headers, k: string, v: string, loc := #caller_location) -> string {
	if h.readonly {
		panic("these headers are readonly, did you accidentally try to set a header on the server request or client response?", loc)
	}

    l := sanitize_key(h^, k)
    h._kv[l] = v
	return l
}

/*
Unsafely set header, given key is assumed to be a lowercase string and to be without newlines. */
headers_set_unsafe :: #force_inline proc(h: ^Headers, k: string, v: string, loc := #caller_location) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the server request or client response?", loc)
	h._kv[k] = v
}

headers_get :: proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return h._kv[sanitize_key(h, k)]
}

/*
Unsafely get header, given key is assumed to be a lowercase string.
*/
headers_get_unsafe :: #force_inline proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return h._kv[k]
}

headers_has :: proc(h: Headers, k: string) -> bool {
	return sanitize_key(h, k) in h._kv
}

/*
Unsafely check for a header, given key is assumed to be a lowercase string.
*/
headers_has_unsafe :: #force_inline proc(h: Headers, k: string) -> bool {
	return k in h._kv
}

headers_delete :: proc(h: ^Headers, k: string) -> (deleted_key: string, deleted_value: string) {
	return delete_key(&h._kv, sanitize_key(h^, k))
}

/*
Unsafely delete a header, given key is assumed to be a lowercase string.
*/
headers_delete_unsafe :: #force_inline proc(h: ^Headers, k: string) {
	delete_key(&h._kv, k)
}

/* Common Helpers */

headers_set_content_type :: proc {
	headers_set_content_type_mime,
	headers_set_content_type_string,
}

headers_set_content_type_string :: #force_inline proc(h: ^Headers, ct: string) {
	headers_set_unsafe(h, "content-type", ct)
}

headers_set_content_type_mime :: #force_inline proc(h: ^Headers, ct: Mime_Type) {
	headers_set_unsafe(h, "content-type", mime_to_content_type(ct))
}

headers_set_close :: #force_inline proc(h: ^Headers) {
	headers_set_unsafe(h, "connection", "close")
}

// Validates the headers of a request, from the pov of the server.
headers_sanitize_for_server :: proc(headers: ^Headers) -> bool {
	// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
	// HTTP/1.1 request message that lacks a Host header field.
	if !headers_has_unsafe(headers^, "host") {
		return false
	}

	return headers_sanitize(headers)
}

// Validates the headers, use `headers_validate_for_server` if these are request headers
// that should be validated from the server side.
headers_sanitize :: proc(headers: ^Headers) -> bool {
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

// Escapes any newlines and converts ASCII to lowercase.
@(private="file")
sanitize_key :: proc(h: Headers, k: string) -> string {
    allocator := h._kv.allocator

	// general +4 in rare case of newlines, so we might not need to reallocate.
	b := strings.builder_make(0, len(k)+4, allocator)
	for c in transmute([]byte)k {
		switch c {
		case 'A'..='Z': strings.write_byte(&b, c + 32)
		case '\n':      strings.write_string(&b, "\\n")
		case:           strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}
