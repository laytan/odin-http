package http

import "core:fmt"
import "core:io"
import "core:path/filepath"
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
requestline_parse :: proc(s: string, allocator := context.temp_allocator) -> (line: Requestline, err: Requestline_Error) {
	s := s

	next_space := strings.index_byte(s, ' ')
	if next_space == -1 do return line, .Not_Enough_Fields

	ok: bool
	line.method, ok = method_parse(s[:next_space])
	if !ok do return line, .Method_Not_Implemented
	s = s[next_space + 1:]

	next_space = strings.index_byte(s, ' ')
	if next_space == -1 do return line, .Not_Enough_Fields

	line.target = strings.clone(s[:next_space], allocator)
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
	switch len(s) {
	case 8:
		(s[6] == '.') or_return
		version.minor = u8(int(s[7]) - '0')
		fallthrough
	case 6:
		(s[:5] == "HTTP/") or_return
		version.major = u8(int(s[5]) - '0')
	case:
		return
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
	for r in Method {
		if _method_strings[r] == m {
			return r, true
		}
	}

	return nil, false
}

// Parses the header and adds it to the headers if valid. The given string is copied.
header_parse :: proc(headers: ^Headers, line: string, allocator := context.allocator) -> (key: string, ok: bool) {
	// Preceding spaces should not be allowed.
	(len(line) > 0 && line[0] != ' ') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	// TODO: see if we can do this only if these are given.
	has_host   := headers_has_unsafe(headers^, "host")
	cl, has_cl := headers_get_unsafe(headers^, "content-length")

	value := strings.clone(strings.trim_space(line[colon + 1:]), allocator)
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
	switch key {
	     // Message framing:
	case "transfer-encoding", "content-length",
	     // Routing:
	     "host",
	     // Request modifiers:
         "if-match", "if-none-match", "if-modified-since", "if-unmodified-since", "if-range",
	     // Authentication:
	     "www-authenticate", "authorization", "proxy-authenticate", "proxy-authorization", "cookie", "set-cookie",
	     // Control data:
	     "age", "cache-control", "expires", "date", "location", "retry-after", "vary", "warning",
	     // How to process:
	     "content-encoding", "content-type", "content-range", "trailer":
		return false
	case:
		return true
	}
}

@(private)
DATE_LENGTH :: len("Fri, 05 Feb 2023 09:01:10 GMT")

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// `<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT`
date_write :: proc(w: io.Writer, t: time.Time) -> io.Error {
	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	wday := time.weekday(t)

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

	if len(target.query) > 0 {
		io.write_byte(w, '?') or_return
		io.write_string(w, target.query) or_return
	}

	return nil
}

request_path :: proc(target: URL, allocator := context.allocator) -> (rq_path: string) {
	res := strings.builder_make(0, len(target.path), allocator)
	request_path_write(strings.to_writer(&res), target)
	return strings.to_string(res)
}

Status :: enum {
	Continue                        = 100,
	Switching_Protocols             = 101,
	Processing                      = 102,
	Early_Hints                     = 103,

	OK                              = 200,
	Created                         = 201,
	Accepted                        = 202,
	Non_Authoritative_Information   = 203,
	No_Content                      = 204,
	Reset_Content                   = 205,
	Partial_Content                 = 206,
	Multi_Status                    = 207,
	Already_Reported                = 208,
	IM_Used                         = 226,

	Multiple_Choices                = 300,
	Moved_Permanently               = 301,
	Found                           = 302,
	See_Other                       = 303,
	Not_Modified                    = 304,
	Use_Proxy                       = 305, // Deprecated.
	Unused                          = 306, // Deprecated.
	Temporary_Redirect              = 307,
	Permanent_Redirect              = 308,

	Bad_Request                     = 400,
	Unauthorized                    = 401,
	Payment_Required                = 402,
	Forbidden                       = 403,
	Not_Found                       = 404,
	Method_Not_Allowed              = 405,
	Not_Acceptable                  = 406,
	Proxy_Authentication_Required   = 407,
	Request_Timeout                 = 408,
	Conflict                        = 409,
	Gone                            = 410,
	Length_Required                 = 411,
	Precondition_Failed             = 412,
	Payload_Too_Large               = 413,
	URI_Too_Long                    = 414,
	Unsupported_Media_Type          = 415,
	Range_Not_Satisfiable           = 416,
	Expectation_Failed              = 417,
	Im_A_Teapot                     = 418,
	Misdirected_Request             = 421,
	Unprocessable_Content           = 422,
	Locked                          = 423,
	Failed_Dependency               = 424,
	Too_Early                       = 425,
	Upgrade_Required                = 426,
	Precondition_Required           = 428,
	Too_Many_Requests               = 429,
	Request_Header_Fields_Too_Large = 431,
	Unavailable_For_Legal_Reasons   = 451,

	Internal_Server_Error           = 500,
	Not_Implemented                 = 501,
	Bad_Gateway                     = 502,
	Service_Unavailable             = 503,
	Gateway_Timeout                 = 504,
	HTTP_Version_Not_Supported      = 505,
	Variant_Also_Negotiates         = 506,
	Insufficient_Storage            = 507,
	Loop_Detected                   = 508,
	Not_Extended                    = 510,
	Network_Authentication_Required = 511,
}

_status_strings: [max(Status) + Status(1)]string

// Populates the status_strings like a map from status to their string representation.
// Where an empty string means an invalid code.
@(init, private)
status_strings_init :: proc() {
	for field in Status {
		name, ok := fmt.enum_value_to_string(field)
		assert(ok)

		b: strings.Builder
		strings.write_int(&b, int(field))
		strings.write_byte(&b, ' ')

		// Some edge cases aside, replaces underscores in the enum name with spaces.
		#partial switch field {
		case .Non_Authoritative_Information: strings.write_string(&b, "Non-Authoritative Information")
		case .Multi_Status:                  strings.write_string(&b, "Multi-Status")
		case .Im_A_Teapot:                   strings.write_string(&b, "I'm a teapot")
		case:
			for c in name {
				switch c {
				case '_': strings.write_rune(&b, ' ')
				case:     strings.write_rune(&b, c)
				}
			}
		}

		_status_strings[field] = strings.to_string(b)
	}
}

status_string :: proc(s: Status) -> string {
	if s >= Status(0) && s <= max(Status) {
		return _status_strings[s]
	}

	return ""
}

status_valid :: proc(s: Status) -> bool {
	return status_string(s) != ""
}

status_from_string :: proc(s: string) -> (Status, bool) {
	if len(s) < 3 do return {}, false

	code_int := int(s[0]-'0')*100 + (int(s[1]-'0')*10) + int(s[2]-'0')

	if !status_valid(Status(code_int)) {
		return {}, false
	}

	return Status(code_int), true
}

status_is_informational :: proc(s: Status) -> bool {
	return s >= Status(100) && s < Status(200)
}

status_is_success :: proc(s: Status) -> bool {
	return s >= Status(200) && s < Status(300)
}

status_is_redirect :: proc(s: Status) -> bool {
	return s >= Status(300) && s < Status(400)
}

status_is_client_error :: proc(s: Status) -> bool {
	return s >= Status(400) && s < Status(500)
}

status_is_server_error :: proc(s: Status) -> bool {
	return s >= Status(500) && s < Status(600)
}

Mime_Type :: enum {
	Plain,

	Css,
	Csv,
	Gif,
	Html,
	Ico,
	Jpeg,
	Js,
	Json,
	Png,
	Svg,
	Url_Encoded,
	Xml,
	Zip,
	Wasm,
}

mime_from_extension :: proc(s: string) -> Mime_Type {
	//odinfmt:disable
	switch filepath.ext(s) {
	case ".html": return .Html
	case ".js":   return .Js
	case ".css":  return .Css
	case ".csv":  return .Csv
	case ".xml":  return .Xml
	case ".zip":  return .Zip
	case ".json": return .Json
	case ".ico":  return .Ico
	case ".gif":  return .Gif
	case ".jpeg": return .Jpeg
	case ".png":  return .Png
	case ".svg":  return .Svg
	case ".wasm": return .Wasm
	case:         return .Plain
	}
	//odinfmt:enable
}

@(private="file")
_mime_to_content_type := [Mime_Type]string{
	.Plain       = "text/plain",

	.Css         = "text/css",
	.Csv         = "text/csv",
	.Gif         = "image/gif",
	.Html        = "text/html",
	.Ico         = "application/vnd.microsoft.ico",
	.Jpeg        = "image/jpeg",
	.Js          = "application/javascript",
	.Json        = "application/json",
	.Png         = "image/png",
	.Svg         = "image/svg+xml",
	.Url_Encoded = "application/x-www-form-urlencoded",
	.Xml         = "text/xml",
	.Zip         = "application/zip",
	.Wasm        = "application/wasm",
}

mime_to_content_type :: proc(m: Mime_Type) -> string {
	assert(m >= .Plain && m <= .Wasm)
	return _mime_to_content_type[m]
}
