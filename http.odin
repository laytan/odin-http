package http

import "core:bytes"
import "core:strconv"
import "core:strings"
import "core:time"

Requestline_Error :: enum {
	None,
	Method_Not_Implemented,
	Not_Enough_Fields,
	Invalid_Version_Format,
}

Requestline :: struct {
	method:  Method,
	target:  string,
	version: Version,
}

// A request-line begins with a method token, followed by a single space
// (SP), the request-target, another single space (SP), the protocol
// version, and ends with CRLF.
//
// This allocates a clone of the target, because this is intended to be used with a scanner,
// which has a buffer that changes every read.
requestline_parse :: proc(s: string, allocator := context.allocator) -> (
	line: Requestline,
	err: Requestline_Error,
) {
	s := s

	next_space := strings.index_byte(s, ' ')
	if next_space == -1 do return line, .Not_Enough_Fields

	ok: bool
	line.method, ok = method_parse(s[:next_space])
	if !ok do return line, .Method_Not_Implemented
	s = s[next_space + 1:]

	next_space = strings.index_byte(s, ' ')
	if next_space == -1 do return line, .Not_Enough_Fields

	// Clone because s (from the scanner) could point to something else later.
	line.target = strings.clone(s[:next_space], allocator)
	s = s[len(line.target) + 1:]

	line.version, ok = version_parse(s)
	if !ok do return line, .Invalid_Version_Format

	return
}

requestline_write :: proc(rline: Requestline, buf: ^bytes.Buffer, allocator := context.allocator) {
	bytes.buffer_write_string(buf, method_string(rline.method))              // <METHOD>
	bytes.buffer_write_byte(buf, ' ')                                        // <METHOD> <SP>
	bytes.buffer_write_string(buf, rline.target)                             // <METHOD> <SP> <TARGET>
	bytes.buffer_write_byte(buf, ' ')                                        // <METHOD> <SP> <TARGET> <SP>
	bytes.buffer_write_string(buf, version_string(rline.version, allocator)) // <METHOD> <SP> <TARGET> <SP> <VERSION>
	bytes.buffer_write_string(buf, "\r\n")                                   // <METHOD> <SP> <TARGET> <SP> <VERSION> <CRLF>
}

Version :: struct {
	major: u8,
	minor: u8,
}

// Parses an HTTP version string according to RFC 7230, section 2.6.
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
	(s[:5] == "HTTP/") or_return
	version.major = u8(int(rune(s[5])) - '0')
	if len(s) > 6 {
		(s[6] == '.') or_return
		version.minor = u8(int(rune(s[7])) - '0')
	}
	ok = true
	return
}

version_string :: proc(v: Version, allocator := context.allocator) -> string {
	str := strings.builder_make(0, 8, allocator)
	strings.write_string(&str, "HTTP/")
	strings.write_rune(&str, '0' + rune(v.major))
	if v.minor > 0 {
		strings.write_rune(&str, '.')
		strings.write_rune(&str, '0' + rune(v.minor))
	}
	return strings.to_string(str)
}

Method :: enum { Get, Head, Post, Put, Patch, Delete, Connect, Options, Trace }

method_parse :: proc(m: string) -> (method: Method, ok: bool) {
	(len(m) <= 7) or_return

	for r in Method {
		if method_string(r) == m {
			return r, true
		}
	}

	return nil, false
}

method_string :: proc(m: Method) -> string {
	switch m {
	case .Get:     return "GET"
	case .Head:    return "HEAD"
	case .Post:    return "POST"
	case .Put:     return "PUT"
	case .Patch:   return "PATCH"
	case .Trace:   return "TRACE"
	case .Delete:  return "DELETE"
	case .Connect: return "CONNECT"
	case .Options: return "OPTIONS"
	case:          return ""
	}
}

// Headers are request or response headers.
//
// They are always parsed to lowercase because they are case-insensitive,
// This allows you to just check the lowercase variant for existence/value.
//
// Thus, you should always add keys in lowercase.
Headers :: map[string]string

// TODO: shoudn't this copy the strings, we are using a scanner which overwrites its buffer right?
header_parse :: proc(headers: ^Headers, line: string, allocator := context.allocator) -> (key: string, ok: bool) {
	// Preceding spaces should not be allowed.
	(len(line) > 0 && line[0] != ' ') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	// Header field names are case-insensitive, so lets represent them all in lowercase.
	key = strings.to_lower(line[:colon], allocator)
	value := strings.trim_space(line[colon + 1:])
	(len(value) > 0) or_return

	// RFC 7230 5.4: Server MUST respond with 400 to any request
	// with multiple "Host" header fields.
	if key == "host" && key in headers {
		return
	}

	// RFC 7230 3.3.3: If a message is received without Transfer-Encoding and with
	// either multiple Content-Length header fields having differing
	// field-values or a single Content-Length header field having an
	// invalid value, then the message framing is invalid and the
	// recipient MUST treat it as an unrecoverable error.
	if key == "content-length" {
		if curr_length, has_length_header := headers[key]; has_length_header {
			(curr_length == value) or_return
		}
	}

	headers[key] = value
	ok = true
	return
}

// Returns if this is a valid trailer header.
//
// RFC 7230 4.1.2:
// A sender MUST NOT generate a trailer that contains a field necessary
// for message framing (e.g., Transfer-Encoding and Content-Length),
// routing (e.g., Host), request modifiers (e.g., controls and
// conditionals in Section 5 of [RFC7231]), authentication (e.g., see
// [RFC7235] and [RFC6265]), response control data (e.g., see Section
// 7.1 of [RFC7231]), or determining how to process the payload (e.g.,
// Content-Encoding, Content-Type, Content-Range, and Trailer).
header_allowed_trailer :: proc(key: string) -> bool {
    return (
        // Message framing:
        key != "transfer-encoding" &&
        key != "content-length" &&
        // Routing:
        key != "host" &&
        // Request modifiers:
        key != "if-match" &&
        key != "if-none-match" &&
        key != "if-modified-since" &&
        key != "if-unmodified-since" &&
        key != "if-range" &&
        // Authentication:
        key != "www-authenticate" &&
        key != "authorization" &&
        key != "proxy-authenticate" &&
        key != "proxy-authorization" &&
        key != "cookie" &&
        key != "set-cookie" &&
        // Control data:
        key != "age" &&
        key != "cache-control" &&
        key != "expires" &&
        key != "date" &&
        key != "location" &&
        key != "retry-after" &&
        key != "vary" &&
        key != "warning" &&
        // How to process:
        key != "content-encoding" &&
        key != "content-type" &&
        key != "content-range" &&
        key != "trailer")
}

@(private)
DATE_LENGTH := len("Fri, 05 Feb 2023 09:01:10 GMT")

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT
format_date_header :: proc(t: time.Time, allocator := context.allocator) -> string {
	b: strings.Builder
	// Init with enough capacity to hold the whole string.
	strings.builder_init(&b, 0, DATE_LENGTH, allocator)

	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	wday := time.weekday(t)

	strings.write_string(&b, DAYS[wday])    // 'Fri, '
	write_padded_int(&b, day)               // 'Fri, 05'
	strings.write_string(&b, MONTHS[month]) // 'Fri, 05 Feb '
	strings.write_int(&b, year)             // 'Fri, 05 Feb 2023'
	strings.write_byte(&b, ' ')             // 'Fri, 05 Feb 2023 '
	write_padded_int(&b, hour)              // 'Fri, 05 Feb 2023 09'
	strings.write_byte(&b, ':')             // 'Fri, 05 Feb 2023 09:'
	write_padded_int(&b, minute)            // 'Fri, 05 Feb 2023 09:01'
	strings.write_byte(&b, ':')             // 'Fri, 05 Feb 2023 09:01:'
	write_padded_int(&b, second)            // 'Fri, 05 Feb 2023 09:01:10'
	strings.write_string(&b, " GMT")        // 'Fri, 05 Feb 2023 09:01:10 GMT'

	return strings.to_string(b)
}

parse_date_header :: proc(value: string) -> (t: time.Time, ok: bool) #no_bounds_check {
	if len(value) != DATE_LENGTH do return

	// Remove 'Fri, '
	value := value
	value = value[5:]

	// Parse '05'
	day := strconv.atoi(value[:2])
	value = value[2:]

	// Parse ' Feb ' or '-Feb-' (latter is a deprecated format but should still be parsed).
	month_index := -1
	month_str := value[1:4]
	value = value[5:]
	for month, i in MONTHS[1:] {
		if month_str == month[1:4] {
			month_index = i
			break
		}
	}
	month_index += 1
	if month_index <= 0 do return

	year := strconv.parse_int(value[:4], 10) or_return
	value = value[4:]

	hour := strconv.parse_int(value[1:3], 10) or_return
	value = value[4:]

	minute := strconv.parse_int(value[:2], 10) or_return
	value = value[3:]

	seconds := strconv.parse_int(value[:2], 10) or_return
	value = value[3:]

	// Should have only 'GMT' left now.
	if value != "GMT" do return

	t = time.datetime_to_time(year, month_index, day, hour, minute, seconds) or_return
	ok = true
	return
}

@(private)
write_padded_int :: proc(b: ^strings.Builder, i: int) {
	if i < 10 {
		strings.write_string(b, PADDED_NUMS[i])
		return
	}

	strings.write_int(b, i)
}

@(private)
PADDED_NUMS := [10]string{"00", "01", "02", "03", "04", "05", "06", "07", "08", "09"}

@(private)
DAYS := [7]string{"Sun, ", "Mon, ", "Tue, ", "Wed, ", "Thu, ", "Fri, ", "Sat, "}

@(private)
MONTHS := [13]string {
	" ", // Jan is 1, so 0 should never be accessed.
	" Jan ",
	" Feb ",
	" Mar ",
	" Apr ",
	" May ",
	" Jun ",
	" Jul ",
	" Aug ",
	" Sep ",
	" Oct ",
	" Nov ",
	" Dec ",
}
