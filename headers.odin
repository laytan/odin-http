package http

import "core:intrinsics"

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
Sets a header, given key is copied and turned into lowercase.
*/
headers_set :: proc(h: ^Headers, k: string, v: string, loc := #caller_location) -> string {
	if h.readonly {
		panic("these headers are readonly, did you accidentally try to set a header on the request?", loc)
	}

	// TODO/PERF: only allocate if the key contains uppercase.

	allocator := h._kv.allocator if h._kv.allocator.procedure != nil else context.allocator
	l := make([]byte, len(k), allocator)

	for b, i in transmute([]byte)k {
		if b >= 'A' && b <= 'Z' {
			l[i] = b + 32
		} else {
			l[i] = b
		}
	}

	h._kv[string(l)] = v
	return string(l)
}

/*
Unsafely set header, given key is assumed to be a lowercase string.
*/
headers_set_unsafe :: #force_inline proc(h: ^Headers, k: string, v: string) {
	assert(!h.readonly)
	h._kv[k] = v
}

headers_get :: proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	l := intrinsics.alloca(len(k), 1)[:len(k)]
	for b, i in transmute([]byte)k {
		if b >= 'A' && b <= 'Z' {
			l[i] = b + 32
		} else {
			l[i] = b
		}
	}

	return h._kv[string(l)]
}

/*
Unsafely get header, given key is assumed to be a lowercase string.
*/
headers_get_unsafe :: #force_inline proc(h: Headers, k: string) -> (string, bool) #optional_ok {
	return h._kv[k]
}

headers_has :: proc(h: Headers, k: string) -> bool {
	l := intrinsics.alloca(len(k), 1)[:len(k)]
	for b, i in transmute([]byte)k {
		if b >= 'A' && b <= 'Z' {
			l[i] = b + 32
		} else {
			l[i] = b
		}
	}

	return string(l) in h._kv
}

/*
Unsafely check for a header, given key is assumed to be a lowercase string.
*/
headers_has_unsafe :: #force_inline proc(h: Headers, k: string) -> bool {
	return k in h._kv
}

headers_delete :: proc(h: ^Headers, k: string) {
	l := intrinsics.alloca(len(k), 1)[:len(k)]
	for b, i in transmute([]byte)k {
		if b >= 'A' && b <= 'Z' {
			l[i] = b + 32
		} else {
			l[i] = b
		}
	}

	delete_key(&h._kv, string(l))
}

/*
Unsafely delete a header, given key is assumed to be a lowercase string.
*/
headers_delete_unsafe :: #force_inline proc(h: ^Headers, k: string) {
	delete_key(&h._kv, k)
}

/* Common Helpers */

headers_set_content_type :: #force_inline proc(h: ^Headers, ct: string) {
	headers_set_unsafe(h, "content-type", ct)
}

headers_set_close :: #force_inline proc(h: ^Headers) {
	headers_set_unsafe(h, "connection", "close")
}
