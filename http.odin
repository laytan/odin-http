package http

import "core:strconv"
import "core:strings"
import "core:time"
import "core:io"
import "core:slice"
import "core:runtime"

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
requestline_parse :: proc(s: string, allocator := context.allocator) -> (line: Requestline, err: Requestline_Error) {
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
	Head,
	Post,
	Put,
	Patch,
	Delete,
	Connect,
	Options,
	Trace,
}

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
	// odinfmt:disable
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
	// odinfmt:enable
}

// TODO: maybe net.percent_encode.
request_path_write :: proc(w: io.Writer, target: URL) -> io.Error {
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

_dynamic_unwritten :: proc(d: [dynamic]$E) -> []E {
	return slice.from_ptr(slice.ptr_add(&d[0], len(d) * size_of(E)), cap(d))
}

_dynamic_add_len :: proc(d: ^[dynamic]$E, len: int) {
	(transmute(^runtime.Raw_Dynamic_Array)d).len += len
}

// TODO: test this.
_write_escaped_newlines :: proc(w: io.Writer, str: string) {
	escaping: bool
	for i in 0..<len(str) {
		if escaping {
			io.write_byte(w, str[i])
			escaping = false
			continue
		}

		if str[i] == '\n' {
			io.write_byte(w, '\\')
			io.write_byte(w, '\n')
		}

		if str[i] == '\\' {
			escaping = true
		}
	}
}
