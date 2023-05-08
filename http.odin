package http

import "core:strings"
import "core:mem"
import "core:time"

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
requestline_parse :: proc(s: string, allocator: mem.Allocator = context.allocator) -> (line: Requestline, ok: bool) {
	s := s

	next_space := strings.index_byte(s, ' ')
	(next_space > -1) or_return

	line.method = method_parse(s[:next_space]) or_return
	s = s[next_space + 1:]

	next_space = strings.index_byte(s, ' ')
	(next_space > -1) or_return

	// Clone because s (from the scanner) could point to something else later.
	line.target = strings.clone(s[:next_space], allocator)
	s = s[len(line.target) + 1:]

	line.version = version_parse(s[:VERSION_LENGTH]) or_return
	ok = true
	return
}

Version :: struct {
	major: u8,
	minor: u8,
}

@(private)
VERSION_LENGTH :: 8

// Parses an HTTP version string according to RFC 7230, section 2.6.
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
	(len(s) == VERSION_LENGTH) or_return
	(s[:5] == "HTTP/") or_return
	version.major = u8(int(rune(s[5])) - '0')
    (s[6] == '.') or_return
	version.minor = u8(int(rune(s[7])) - '0')
	ok = true
	return
}

version_string :: proc(v: Version, allocator: mem.Allocator = context.allocator) -> string {
	str := strings.builder_make(VERSION_LENGTH, VERSION_LENGTH, allocator)
	strings.write_string(&str, "HTTP/")
	strings.write_rune(&str, '0' + rune(v.major))
	strings.write_rune(&str, '.')
	strings.write_rune(&str, '0' + rune(v.minor))
	return strings.to_string(str)
}

Method :: enum { Get, Head, Post, Put, Delete, Connect, Options, Trace }

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
	case .Trace:   return "TRACE"
	case .Delete:  return "DELETE"
	case .Connect: return "CONNECT"
	case .Options: return "OPTIONS"
	case:          return ""
	}
}

Headers :: map[string]string

header_parse :: proc(headers: ^Headers, line: string) -> (key: string, ok: bool) {
	// Preceding spaces should not be allowed.
	(len(line) > 0 && line[0] != ' ') or_return

	colon := strings.index_byte(line, ':')
	(colon > -1) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	key = line[:colon]
	value := strings.trim_space(line[colon + 1:])
	(len(value) > 0) or_return

    // RFC 7230 5.4: Server MUST respond with 400 to any request
    // with multiple "Host" header fields.
    if key == "Host" && key in headers {
        return
    }

    // RFC 7230 3.3.3: If a message is received without Transfer-Encoding and with
    // either multiple Content-Length header fields having differing
    // field-values or a single Content-Length header field having an
    // invalid value, then the message framing is invalid and the
    // recipient MUST treat it as an unrecoverable error.
    if key == "Content-Length" {
        if curr_length, ok := headers[key]; ok {
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
        key != "Transfer-Encoding" &&
        key != "Content-Length" &&
        // Routing:
        key != "Host" &&
        // Request modifiers:
        key != "If-Match" &&
        key != "If-None-Match" &&
        key != "If-Modified-Since" &&
        key != "If-Unmodified-Since" &&
        key != "If-Range" &&
        // Authentication:
        key != "WWW-Authenticate" &&
        key != "Authorization" &&
        key != "Proxy-Authenticate" &&
        key != "Proxy-Authorization" &&
        key != "Cookie" &&
        key != "Set-Cookie" &&
        // Control data:
        key != "Age" &&
        key != "Cache-Control" &&
        key != "Expires" &&
        key != "Date" &&
        key != "Location" &&
        key != "Retry-After" &&
        key != "Vary" &&
        key != "Warning" &&
        // How to process:
        key != "Content-Encoding" &&
        key != "Content-Type" &&
        key != "Content-Range" &&
        key != "Trailer"
    )
}

@(private)
DATE_LENGTH := len("Fri, 5 Feb 2023 09:01:10 GMT")

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT
format_date_header :: proc(t: time.Time, allocator: mem.Allocator = context.allocator) -> string {
	b: strings.Builder
    // Init with enough capacity to hold the whole string.
	strings.builder_init(&b, 0, DATE_LENGTH, allocator)

	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	wday := time.weekday(t)

	strings.write_string(&b, DAYS[wday])    // 'Fri, '
	write_padded_int(&b, day)               // 'Fri, 5'
	strings.write_string(&b, MONTHS[month]) // 'Fri, 5 Feb '
	strings.write_int(&b, year)             // 'Fri, 5 Feb 2023'
	strings.write_byte(&b, ' ')             // 'Fri, 5 Feb 2023 '
	write_padded_int(&b, hour)              // 'Fri, 5 Feb 2023 09'
	strings.write_byte(&b, ':')             // 'Fri, 5 Feb 2023 09:'
	write_padded_int(&b, minute)            // 'Fri, 5 Feb 2023 09:01'
	strings.write_byte(&b, ':')             // 'Fri, 5 Feb 2023 09:01:'
	write_padded_int(&b, second)            // 'Fri, 5 Feb 2023 09:01:10'
	strings.write_string(&b, " GMT")        // 'Fri, 5 Feb 2023 09:01:10 GMT'

	return strings.to_string(b)
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
	" Jan ", " Feb ", " Mar ",
    " Apr ", " May ", " Jun ",
    " Jul ", " Aug ", " Sep ",
    " Oct ", " Nov ", " Dec ",
}
