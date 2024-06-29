//+build !js
package http

import "core:net"

Request :: struct {
	// If in a handler, this is always there and never None.
	// TODO: we should not expose this as a maybe to package users.
	line:       Maybe(Requestline),

	// Is true if the request is actually a HEAD request,
	// line.method will be .Get if Server_Opts.redirect_head_to_get is set.
	is_head:    bool,

	url:        URL,
	client:     net.Endpoint,

	// Route params/captures.
	url_params: []string,

	using _: Has_Body,
}


/*
Retrieves the cookie with the given `key` out of the request's `Cookie` header.

If the same key is in the header multiple times the last one is returned.
*/
request_cookie_get :: proc(r: ^Request, key: string) -> (value: string, ok: bool) {
	cookies := headers_get_unsafe(r.headers, "cookie") or_return

	for k, v in request_cookies_iter(&cookies) {
		if key == k do return v, true
	}

	return
}

/*
Allocates a map with the given allocator and puts all cookie pairs from the request's `Cookie` header into it.

If the same key is in the header multiple times the last one is returned.
*/
request_cookies :: proc(r: ^Request, allocator := context.temp_allocator) -> (res: map[string]string) {
	res.allocator = allocator

	cookies := headers_get_unsafe(r.headers, "cookie") or_else ""
	for k, v in request_cookies_iter(&cookies) {
		// Don't overwrite, the iterator goes from right to left and we want the last.
		if k in res do continue

		res[k] = v
	}

	return
}

/*
Iterates the cookies (from the `Cookie` header) from right to left.
*/
request_cookies_iter :: proc(cookies: ^string) -> (key: string, value: string, ok: bool) {
	end := len(cookies)
	eq  := -1
	for i := end-1; i >= 0; i-=1 {
		b := cookies[i]
		start := i == 0
		sep := start || b == ' ' && cookies[i-1] == ';'
		if sep {
			defer end = i - 1

			// Invalid.
			if eq < 0 {
				continue
			}

			off := 0 if start else 1

			key   = cookies[i+off:eq]
			value = cookies[eq+1:end]

			cookies^ = cookies[:i-off]

			return key, value, true
		} else if b == '=' {
			eq = i
		}
	}

	return
}
