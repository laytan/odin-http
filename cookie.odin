package http

import "core:strconv"
import "core:strings"
import "core:time"

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
