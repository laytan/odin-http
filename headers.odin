package http

import "core:strings"

// A case-insensitive ASCII map for storing headers.
Headers :: struct {
	_kv:      map[string]string,
	readonly: bool,
}

headers_init :: proc(h: ^Headers, allocator := context.temp_allocator) {
	h._kv.allocator = allocator
}

headers_count :: #force_inline proc(h: Headers) -> int {
	return len(h._kv)
}

/*
Sets a header, given key is first sanitized, final (sanitized) key is returned.
*/
headers_set :: proc(h: ^Headers, k: string, v: string, loc := #caller_location) -> string {
	if h.readonly {
		panic("these headers are readonly, did you accidentally try to set a header on the request?", loc)
	}

    l := sanitize_key(h^, k)
    h._kv[l] = v
	return l
}

/*
Unsafely set header, given key is assumed to be a lowercase string and to be without newlines.
*/
headers_set_unsafe :: #force_inline proc(h: ^Headers, k: string, v: string, loc := #caller_location) {
	assert(!h.readonly, "these headers are readonly, did you accidentally try to set a header on the request?", loc)
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

/*
Escapes any newlines and converts ASCII to lowercase.
*/
@(private="file")
sanitize_key :: proc(h: Headers, k: string) -> string {
    allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.temp_allocator

	// general +4 in rare case of newlines, so we might not need to reallocate.
	b := strings.builder_make(0, len(k)+4, allocator)
	for c in k {
		switch c {
		case 'A'..='Z': strings.write_rune(&b, c + 32)
		case '\n':      strings.write_string(&b, "\\n")
		case:           strings.write_rune(&b, c)
		}
	}
	return strings.to_string(b)

    // NOTE: implementation that only allocates if needed, but we use arena's anyway so just allocating
    // some space should be about as fast?
    //
	// b: strings.Builder = ---
	// i: int
	// for c in v {
	// 	if c == '\n' || (c >= 'A' && c <= 'Z') {
	// 		b = strings.builder_make(0, len(v)+4, allocator)
	// 		strings.write_string(&b, v[:i])
	// 		alloc = true
	// 		break
	// 	}
	// 	i+=1
	// }
	//
	// if !alloc {
	// 	return v, false
	// }
	//
	// for c in v[i:] {
	//  switch c {
	//  case 'A'..='Z': strings.write_rune(&b, c + 32)
	//  case '\n':      strings.write_string(&b, "\\n")
	//  case:           strings.write_rune(&b, c)
	//  }
	// }
	//
	// return strings.to_string(b), true
}
