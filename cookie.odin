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
	_raw:         string,
	name:         string,
	value:        string,
	domain:       Maybe(string),
	expires_gmt:  Maybe(time.Time),
	max_age_secs: Maybe(int),
	path:         Maybe(string),
	http_only:    bool,
	partitioned:  bool,
	secure:       bool,
	same_site:    Cookie_Same_Site,
}

// Builds the Set-Cookie header string representation of the given cookie.
cookie_write :: proc(w: io.Writer, c: Cookie) -> io.Error {
	// odinfmt:disable
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
	if eq < 1 { return }

	cookie._raw = value
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
			defer delete(key, allocator)

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
			defer delete(key, allocator)

			value := part[eq + 1:]

			switch key {
			case "domain":
				cookie.domain = value
			case "expires":
				cookie.expires_gmt = cookie_date_parse(value) or_return
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

	for semi = strings.index_byte(value, ';'); semi != -1; semi = strings.index_byte(value, ';') {
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
Implementation of the algorithm described in RFC 6265 section 5.1.1.
*/
cookie_date_parse :: proc(value: string) -> (t: time.Time, ok: bool) {

	iter_delim :: proc(value: ^string) -> (token: string, ok: bool) {
		start := -1
		start_loop: for ch, i in transmute([]byte)value^ {
			switch ch {
			case 0x09, 0x20..=0x2F, 0x3B..=0x40, 0x5B..=0x60, 0x7B..=0x7E:
			case:
				start = i
				break start_loop
			}
		}

		if start == -1 {
			return
		}

		token = value[start:]
		length := len(token)
		end_loop: for ch, i in transmute([]byte)token {
			switch ch {
			case 0x09, 0x20..=0x2F, 0x3B..=0x40, 0x5B..=0x60, 0x7B..=0x7E:
				length = i
				break end_loop
			}
		}

		ok = true

		token  = token[:length]
		value^ = value[start+length:]
		return
	}

	parse_digits :: proc(value: string, min, max: int, trailing_ok: bool) -> (int, bool) {
		count: int
		for ch in transmute([]byte)value {
			if ch <= 0x2f || ch >= 0x3a {
				break
			}
			count += 1
		}

		if count < min || count > max {
			return 0, false
		}

		if !trailing_ok && len(value) != count {
			return 0, false
		}

		return strconv.parse_int(value[:count], 10)
	}

	parse_time :: proc(token: string) -> (t: Time, ok: bool) {
		hours, match1, tail := strings.partition(token, ":")
		if match1 != ":" { return }
		minutes, match2, seconds := strings.partition(tail,  ":")
		if match2 != ":" { return }

		t.hours   = parse_digits(hours,   1, 2, false) or_return
		t.minutes = parse_digits(minutes, 1, 2, false) or_return
		t.seconds = parse_digits(seconds, 1, 2, true)  or_return

		ok = true
		return
	}

	parse_month :: proc(token: string) -> (month: int) {
		if len(token) < 3 {
			return
		}

		lower: [3]byte
		for &ch, i in lower {
			#no_bounds_check orig := token[i]
			switch orig {
			case 'A'..='Z':
				ch = orig + 32
			case:
				ch = orig
			}
		}

		switch string(lower[:]) {
		case "jan":
			return 1
		case "feb":
			return 2
		case "mar":
			return 3
		case "apr":
			return 4
		case "may":
			return 5
		case "jun":
			return 6
		case "jul":
			return 7
		case "aug":
			return 8
		case "sep":
			return 9
		case "oct":
			return 10
		case "nov":
			return 11
		case "dec":
			return 12
		case:
			return
		}
	}

	Time :: struct {
		hours, minutes, seconds: int,
	}

	clock: Maybe(Time)
	day_of_month, month, year: Maybe(int)

	value := value
	for token in iter_delim(&value) {
		if _, has_time := clock.?; !has_time {
			if t, tok := parse_time(token); tok {
				clock = t
				continue
			}
		}

		if _, has_day_of_month := day_of_month.?; !has_day_of_month {
			if dom, dok := parse_digits(token, 1, 2, true); dok {
				day_of_month = dom
				continue
			}
		}

		if _, has_month := month.?; !has_month {
			if mon := parse_month(token); mon > 0 {
				month = mon
				continue
			}
		}

		if _, has_year := year.?; !has_year {
			if yr, yrok := parse_digits(token, 2, 4, true); yrok {

				if yr >= 70 && yr <= 99 {
					yr += 1900
				} else if yr >= 0 && yr <= 69 {
					yr += 2000
				}

				year = yr
				continue
			}
		}
	}

	c := clock.? or_return
	y := year.?  or_return

	if y < 1601 {
		return
	}

	t = time.datetime_to_time(
		y,
		month.?        or_return,
		day_of_month.? or_return,
		c.hours,
		c.minutes,
		c.seconds,
	) or_return

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
		if key == k { return v, true }
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
		if k in res { continue }

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
