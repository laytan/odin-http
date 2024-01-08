package http

import "core:io"
import "core:strconv"
import "core:strings"
import "core:time"

Cookie_Same_Site :: enum {
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
	same_site:    Cookie_Same_Site,
	secure:       bool,
}

// Builds the Set-Cookie header string representation of the given cookie.
cookie_write :: proc(w: io.Writer, c: Cookie) -> io.Error {
	// odinfmt:disable
	io.write_string(w, "set-cookie: ") or_return
	io.write_string(w, c.name)         or_return
	write_escaped_newlines(w, c.name)  or_return
	io.write_byte(w, '=')              or_return
	write_escaped_newlines(w, c.value) or_return

	if d, ok := c.domain.(string); ok {
		io.write_string(w, "; Domain=") or_return
		write_escaped_newlines(w, d)    or_return
	}

	if e, ok := c.expires_gmt.(time.Time); ok {
		io.write_string(w, "; Expires=") or_return
		date_write(w, e)                 or_return
	}

	if a, ok := c.max_age_secs.(int); ok {
		io.write_string(w, "; Max-Age=") or_return
		io.write_int(w, a)               or_return
	}

	if p, ok := c.path.(string); ok {
		io.write_string(w, "; Path=") or_return
		write_escaped_newlines(w, p)  or_return
	}

	switch c.same_site {
	case .None:   io.write_string(w, "; SameSite=None")   or_return
	case .Lax:    io.write_string(w, "; SameSite=Lax")    or_return
	case .Strict: io.write_string(w, "; SameSite=Strict") or_return
	case .Unspecified: // no-op.
	}
	// odinfmt:enable

	if c.secure {
		io.write_string(w, "; Secure") or_return
	}

	if c.partitioned {
		io.write_string(w, "; Partitioned") or_return
	}

	if c.http_only {
		io.write_string(w, "; HttpOnly") or_return
	}

	return nil
}

// Builds the Set-Cookie header string representation of the given cookie.
cookie_string :: proc(c: Cookie, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, 0, 20, allocator)

	cookie_write(strings.to_writer(&b), c)

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
	value = value[eq + 1:]

	semi := strings.index_byte(value, ';')
	switch semi {
	case -1:
		cookie.value = value
		ok = true
		return
	case 0:
		return
	case:
		cookie.value = value[:semi]
		value = value[semi + 1:]
	}

	parse_part :: proc(cookie: ^Cookie, part: string, allocator := context.temp_allocator) -> (ok: bool) {
		eq := strings.index_byte(part, '=')
		switch eq {
		case -1:
			key := strings.to_lower(part, allocator)
			defer delete(key)

			switch key {
			case "httponly":
				cookie.http_only = true
			case "partitioned":
				cookie.partitioned = true
			case "secure":
				cookie.secure = true
			case:
				return
			}
		case 0:
			return
		case:
			key := strings.to_lower(part[:eq], allocator)
			defer delete(key)

			value := part[eq + 1:]

			switch key {
			case "domain":
				cookie.domain = value
			case "expires":
				cookie.expires_gmt = date_parse(value) or_return
			case "max-age":
				cookie.max_age_secs = strconv.parse_int(value, 10) or_return
			case "path":
				cookie.path = value
			case "samesite":
				switch value {
				case "lax", "Lax", "LAX":
					cookie.same_site = .Lax
				case "none", "None", "NONE":
					cookie.same_site = .None
				case "strict", "Strict", "STRICT":
					cookie.same_site = .Strict
				case:
					return
				}
			case:
				return
			}
		}
		return true
	}

	for semi := strings.index_byte(value, ';'); semi != -1; semi = strings.index_byte(value, ';') {
		part := strings.trim_left_space(value[:semi])
		value = value[semi + 1:]
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

/*
Retrieves the cookie with the given `key` out of the requests `Cookie` header.

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
Allocates a map with the given allocator and puts all cookie pairs from the requests `Cookie` header into it.

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
Iterates the cookies from right to left.
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

			key := cookies[i+off:eq]
			val := cookies[eq+1:end]

			cookies^ = cookies[:i-off]

			return key, val, true
		} else if b == '=' {
			eq = i
		}
	}

	return
}
