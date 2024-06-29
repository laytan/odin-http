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

// Writes the `Set-Cookie` header string representation of the given cookie.
cookie_write :: proc(w: io.Writer, c: Cookie) -> io.Error {
	io.write_string(w, "set-cookie: ") or_return
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

// Parses a `Set-Cookie` header value.
//
// TODO: check specific whitespace requirements in RFC.
cookie_parse :: proc(value: string) -> (cookie: Cookie, ok: bool) {
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

	parse_part :: proc(cookie: ^Cookie, part: string) -> (ok: bool) {
		eq := strings.index_byte(part, '=')
		switch eq {
		case -1:
			switch {
			case ascii_case_insensitive_eq(part, "httponly"):
				cookie.http_only = true
			case ascii_case_insensitive_eq(part, "partitioned"):
				cookie.partitioned = true
			case ascii_case_insensitive_eq(part, "secure"):
				cookie.secure = true
			case:
				return
			}
		case 0:
			return
		case:
			key   := part[:eq]
			value := part[eq + 1:]

			switch {
			case ascii_case_insensitive_eq(key, "domain"):
				cookie.domain = value
			case ascii_case_insensitive_eq(key, "expires"):
				cookie.expires_gmt = date_parse(value) or_return
			case ascii_case_insensitive_eq(key, "max-age"):
				cookie.max_age_secs = strconv.parse_int(value, 10) or_return
			case ascii_case_insensitive_eq(key, "path"):
				cookie.path = value
			case ascii_case_insensitive_eq(key, "samesite"):
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

	for semi = strings.index_byte(value, ';'); semi != -1; semi = strings.index_byte(value, ';') {
		part := strings.trim_left_space(value[:semi])
		value = value[semi + 1:]
		parse_part(&cookie, part) or_return
	}

	part := strings.trim_left_space(value)
	if part == "" {
		ok = true
		return
	}

	parse_part(&cookie, part) or_return
	ok = true
	return
}
