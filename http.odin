package http

import "core:io"
import "core:runtime"
import "core:slice"
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
	target:  union {
		string,
		URL,
	},
	version: Version,
}

// A request-line begins with a method token, followed by a single space
// (SP), the request-target, another single space (SP), the protocol
// version, and ends with CRLF.
//
// This allocates a clone of the target, because this is intended to be used with a scanner,
// which has a buffer that changes every read.
requestline_parse :: proc(s: string) -> (line: Requestline, err: Requestline_Error) {
	s := s

	next_space := strings.index_byte(s, ' ')
	if next_space == -1 do return line, .Not_Enough_Fields

	ok: bool
	line.method, ok = method_parse(s[:next_space])
	if !ok do return line, .Method_Not_Implemented
	s = s[next_space + 1:]

	next_space = strings.index_byte(s, ' ')
	if next_space == -1 do return line, .Not_Enough_Fields

	line.target = s[:next_space]
	s = s[len(line.target.(string)) + 1:]

	line.version, ok = version_parse(s)
	if !ok do return line, .Invalid_Version_Format

	return
}

requestline_write :: proc(w: io.Writer, rline: Requestline) -> io.Error {
	// odinfmt:disable
	io.write_string(w, method_string(rline.method)) or_return // <METHOD>
	io.write_byte(w, ' ')                           or_return // <METHOD> <SP>

	switch t in rline.target {
	case string: io.write_string(w, t)              or_return // <METHOD> <SP> <TARGET>
	case URL:    request_path_write(w, t)           or_return // <METHOD> <SP> <TARGET>
	}

	io.write_byte(w, ' ')                           or_return // <METHOD> <SP> <TARGET> <SP>
	version_write(w, rline.version)                 or_return // <METHOD> <SP> <TARGET> <SP> <VERSION>
	io.write_string(w, "\r\n")                      or_return // <METHOD> <SP> <TARGET> <SP> <VERSION> <CRLF>
	// odinfmt:enable

	return nil
}

Version :: struct {
	major: u8,
	minor: u8,
}

// Parses an HTTP version string according to RFC 7230, section 2.6.
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
	(len(s) > 5) or_return
	(s[:5] == "HTTP/") or_return
	version.major = u8(int(rune(s[5])) - '0')
	if len(s) > 6 {
		(s[6] == '.') or_return
		version.minor = u8(int(rune(s[7])) - '0')
	}
	ok = true
	return
}

version_write :: proc(w: io.Writer, v: Version) -> io.Error {
	io.write_string(w, "HTTP/") or_return
	io.write_rune(w, '0' + rune(v.major)) or_return
	if v.minor > 0 {
		io.write_rune(w, '.')
		io.write_rune(w, '0' + rune(v.minor))
	}

	return nil
}

version_string :: proc(v: Version, allocator := context.allocator) -> string {
	buf := make([]byte, 8, allocator)

	b: strings.Builder
	b.buf = slice.into_dynamic(buf)

	version_write(strings.to_writer(&b), v)

	return strings.to_string(b)
}

Method :: enum {
	Get,
	Post,
	Delete,
	Patch,
	Put,
	Head,
	Connect,
	Options,
	Trace,
}

_method_strings := [?]string{"GET", "POST", "DELETE", "PATCH", "PUT", "HEAD", "CONNECT", "OPTIONS", "TRACE"}

method_string :: proc(m: Method) -> string #no_bounds_check {
	if m < .Get || m > .Trace do return ""
	return _method_strings[m]
}

method_parse :: proc(m: string) -> (method: Method, ok: bool) #no_bounds_check {
	// PERF: I assume this is faster than a map with this amount of items.

	for r in Method {
		if _method_strings[r] == m {
			return r, true
		}
	}

	return nil, false
}

header_parse :: proc(headers: ^Headers, line: string, allocator := context.temp_allocator) -> (key: string, ok: bool) {
	// Preceding spaces should not be allowed.
	(len(line) > 0 && line[0] != ' ') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	// TODO/PERF: only actually relevant/needed if the key is one of these.
	has_host   := headers_has_unsafe(headers^, "host")
	cl, has_cl := headers_get_unsafe(headers^, "content-length")

	value := strings.trim_space(line[colon + 1:])
	key = headers_set(headers, line[:colon], value)

	// RFC 7230 5.4: Server MUST respond with 400 to any request
	// with multiple "Host" header fields.
	if key == "host" && has_host {
		return
	}

	// RFC 7230 3.3.3: If a message is received without Transfer-Encoding and with
	// either multiple Content-Length header fields having differing
	// field-values or a single Content-Length header field having an
	// invalid value, then the message framing is invalid and the
	// recipient MUST treat it as an unrecoverable error.
	if key == "content-length" && has_cl && cl != value {
		return
	}

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
	// odinfmt:disable
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
	// odinfmt:enable
}

@(private)
DATE_LENGTH :: len("Fri, 05 Feb 2023 09:01:10 GMT")

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// `<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT`
date_write :: proc(w: io.Writer, t: time.Time) -> io.Error {
	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	wday := time.weekday(t)

	// odinfmt:disable
	io.write_string(w, DAYS[wday])    or_return // 'Fri, '
	write_padded_int(w, day)          or_return // 'Fri, 05'
	io.write_string(w, MONTHS[month]) or_return // 'Fri, 05 Feb '
	io.write_int(w, year)             or_return // 'Fri, 05 Feb 2023'
	io.write_byte(w, ' ')             or_return // 'Fri, 05 Feb 2023 '
	write_padded_int(w, hour)         or_return // 'Fri, 05 Feb 2023 09'
	io.write_byte(w, ':')             or_return // 'Fri, 05 Feb 2023 09:'
	write_padded_int(w, minute)       or_return // 'Fri, 05 Feb 2023 09:01'
	io.write_byte(w, ':')             or_return // 'Fri, 05 Feb 2023 09:01:'
	write_padded_int(w, second)       or_return // 'Fri, 05 Feb 2023 09:01:10'
	io.write_string(w, " GMT")        or_return // 'Fri, 05 Feb 2023 09:01:10 GMT'
	// odinfmt:enable

	return nil
}

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// `<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT`
date_string :: proc(t: time.Time, allocator := context.allocator) -> string {
	b: strings.Builder

	buf := make([]byte, DATE_LENGTH, allocator)
	b.buf = slice.into_dynamic(buf)

	date_write(strings.to_writer(&b), t)

	return strings.to_string(b)
}

date_parse :: proc(value: string) -> (t: time.Time, ok: bool) #no_bounds_check {
	if len(value) != DATE_LENGTH do return

	// Remove 'Fri, '
	value := value
	value = value[5:]

	// Parse '05'
	day := strconv.parse_i64_of_base(value[:2], 10) or_return
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

	year := strconv.parse_i64_of_base(value[:4], 10) or_return
	value = value[4:]

	hour := strconv.parse_i64_of_base(value[1:3], 10) or_return
	value = value[4:]

	minute := strconv.parse_i64_of_base(value[:2], 10) or_return
	value = value[3:]

	seconds := strconv.parse_i64_of_base(value[:2], 10) or_return
	value = value[3:]

	// Should have only 'GMT' left now.
	if value != "GMT" do return

	t = time.datetime_to_time(int(year), int(month_index), int(day), int(hour), int(minute), int(seconds)) or_return
	ok = true
	return
}

request_path_write :: proc(w: io.Writer, target: URL) -> io.Error {
	// TODO: maybe net.percent_encode.

	if target.path == "" {
		io.write_byte(w, '/') or_return
	} else {
		io.write_string(w, target.path) or_return
	}

	if len(target.queries) > 0 {
		io.write_byte(w, '?') or_return

		i := 0
		for key, value in target.queries {
			io.write_string(w, key) or_return
			if value != "" {
				io.write_byte(w, '=') or_return
				io.write_string(w, value) or_return
			}

			if i != len(target.queries) - 1 {
				io.write_byte(w, '&') or_return
			}

			i += 1
		}
	}

	return nil
}

request_path :: proc(target: URL, allocator := context.allocator) -> (rq_path: string) {
	res := strings.builder_make(0, len(target.path), allocator)
	request_path_write(strings.to_writer(&res), target)
	return strings.to_string(res)
}

_dynamic_unwritten :: proc(d: [dynamic]$E) -> []E  {
	return (cast([^]E)raw_data(d))[len(d):cap(d)]
}

_dynamic_add_len :: proc(d: ^[dynamic]$E, len: int) {
	(transmute(^runtime.Raw_Dynamic_Array)d).len += len
}

@(private)
write_padded_int :: proc(w: io.Writer, i: int) -> io.Error {
	if i < 10 {
		io.write_string(w, PADDED_NUMS[i]) or_return
		return nil
	}

	_, err := io.write_int(w, i)
	return err
}

@(private)
write_escaped_newlines :: proc(w: io.Writer, v: string) -> io.Error {
	for c in v {
		if c == '\n' {
			io.write_string(w, "\\n") or_return
		} else {
			io.write_rune(w, c) or_return
		}
	}
	return nil
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

import "core:testing"

@(test)
test_dynamic_unwritten :: proc(t: ^testing.T) {
	{
		d  := make([dynamic]int, 4, 8)
		du := _dynamic_unwritten(d)

		testing.expect(t, len(du) == 4)
	}

	{
		d := slice.into_dynamic([]int{1, 2, 3, 4, 5})
		_dynamic_add_len(&d, 3)
		du := _dynamic_unwritten(d)

		testing.expect(t, len(d)  == 3)
		testing.expect(t, len(du) == 2)
		testing.expect(t, du[0] == 4)
		testing.expect(t, du[1] == 5)
	}

	{
		d := slice.into_dynamic([]int{})
		du := _dynamic_unwritten(d)

		testing.expect(t, len(du) == 0)
	}
}

