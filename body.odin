package http

import "core:bufio"
import "core:io"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"

Body :: string

Body_Callback :: #type proc(user_data: rawptr, body: Body, err: Body_Error)

Body_Error :: bufio.Scanner_Error

/*
Retrieves the request's body.

If the request has the chunked Transfer-Encoding header set, the chunks are all read and returned.
Otherwise, the Content-Length header is used to determine what to read and return it.

`max_length` can be used to set a maximum amount of bytes we try to read, once it goes over this,
an error is returned.

Do not call this more than once.

**Tip** If an error is returned, easily respond with an appropriate error code like this, `http.respond(res, http.body_error_status(err))`.
*/
body :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	assert(req._body_ok == nil, "you can only call body once per request")

	enc_header, ok := headers_get_unsafe(req.headers, "transfer-encoding")
	if ok && strings.has_suffix(enc_header, "chunked") {
		_body_chunked(req, max_length, user_data, cb)
	} else {
		_body_length(req, max_length, user_data, cb)
	}
}

/*
Parses a URL encoded body, aka bodies with the 'Content-Type: application/x-www-form-urlencoded'.

Key&value pairs are percent decoded and put in a map.
*/
body_url_encoded :: proc(plain: Body, allocator := context.temp_allocator) -> (res: map[string]string, ok: bool) {

	insert :: proc(m: ^map[string]string, plain: string, keys: int, vals: int, end: int, allocator := context.temp_allocator) -> bool {
		has_value := vals != -1
		key_end   := vals - 1 if has_value else end
		key       := plain[keys:key_end]
		val       := plain[vals:end] if has_value else ""

		// PERF: this could be a hot spot and I don't like that we allocate the decoded key and value here.
		keye := (net.percent_decode(key, allocator) or_return) if strings.index_byte(key, '%') > -1 else key
		vale := (net.percent_decode(val, allocator) or_return) if has_value && strings.index_byte(val, '%') > -1 else val

		m[keye] = vale
		return true
	}

	count := 1
	for b in plain {
		if b == '&' do count += 1
	}

	queries := make(map[string]string, count, allocator)

	keys := 0
	vals := -1
	for b, i in plain {
		switch b {
		case '=':
			vals = i + 1
		case '&':
			insert(&queries, plain, keys, vals, i) or_return
			keys = i + 1
			vals = -1
		}
	}

	insert(&queries, plain, keys, vals, len(plain)) or_return

	return queries, true
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(e: Body_Error) -> Status {
	switch t in e {
	case bufio.Scanner_Extra_Error:
		switch t {
		case .Too_Long:                            return .Payload_Too_Large
		case .Too_Short, .Bad_Read_Count:          return .Bad_Request
		case .Negative_Advance, .Advanced_Too_Far: return .Internal_Server_Error
		case .None:                                return .OK
		case:
			return .Internal_Server_Error
		}
	case io.Error:
		switch t {
		case .EOF, .Unknown, .No_Progress, .Unexpected_EOF:
			return .Bad_Request
		case .Empty, .Short_Write, .Buffer_Full, .Short_Buffer,
		     .Invalid_Write, .Negative_Read, .Invalid_Whence, .Invalid_Offset,
			 .Invalid_Unread, .Negative_Write, .Negative_Count:
			return .Internal_Server_Error
		case .None:
			return .OK
		case:
			return .Internal_Server_Error
		}
	case: unreachable()
	}
}


// "Decodes" a request body based on the content length header.
// Meant for internal usage, you should use `http.request_body`.
_body_length :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	req._body_ok = false

	len, ok := headers_get_unsafe(req.headers, "content-length")
	if !ok {
		cb(user_data, "", nil)
		return
	}

	ilen, lenok := strconv.parse_int(len, 10)
	if !lenok {
		cb(user_data, "", .Bad_Read_Count)
		return
	}

	if max_length > -1 && ilen > max_length {
		cb(user_data, "", .Too_Long)
		return
	}

	if ilen == 0 {
		req._body_ok = true
		cb(user_data, "", nil)
		return
	}

	req._scanner.max_token_size = ilen

	req._scanner.split          = scan_num_bytes
	req._scanner.split_data     = rawptr(uintptr(ilen))

	req._body_ok = true
	scanner_scan(req._scanner, user_data, cb)
}

/*
"Decodes" a chunked transfer encoded request body.
Meant for internal usage, you should use `http.request_body`.

PERF: this could be made non-allocating by writing over the part of the body that contains the
metadata with the rest of the body, and then returning a slice of that, but it is some effort and
I don't think this functionality of HTTP is used that much anyway.

RFC 7230 4.1.3 pseudo-code:

length := 0
read chunk-size, chunk-ext (if any), and CRLF
while (chunk-size > 0) {
   read chunk-data and CRLF
   append chunk-data to decoded-body
   length := length + chunk-size
   read chunk-size, chunk-ext (if any), and CRLF
}
read trailer field
while (trailer field is not empty) {
   if (trailer field is allowed to be sent in a trailer) {
   	append trailer field to existing header fields
   }
   read trailer-field
}
Content-Length := length
Remove "chunked" from Transfer-Encoding
Remove Trailer from existing header fields
*/
_body_chunked :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	req._body_ok = false

	on_scan :: proc(s: rawptr, size_line: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s
		size_line := size_line

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := strings.index_byte(size_line, ';'); semi > -1 {
			size_line = size_line[:semi]
		}

		size, ok := strconv.parse_int(string(size_line), 16)
		if !ok {
			log.infof("Encountered an invalid chunk size when decoding a chunked body: %q", string(size_line))
			s.cb(s.user_data, "", .Bad_Read_Count)
			return
		}

		// start scanning trailer headers.
		if size == 0 {
			scanner_scan(s.req._scanner, s, on_scan_trailer)
			return
		}

		if s.max_length > -1 && strings.builder_len(s.buf) + size > s.max_length {
			s.cb(s.user_data, "", .Too_Long)
			return
		}

		s.req._scanner.max_token_size = size

		s.req._scanner.split          = scan_num_bytes
		s.req._scanner.split_data     = rawptr(uintptr(size))

		scanner_scan(s.req._scanner, s, on_scan_chunk)
	}

	on_scan_chunk :: proc(s: rawptr, token: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}

		s.req._scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		s.req._scanner.split          = scan_lines

		strings.write_string(&s.buf, token)

		on_scan_empty_line :: proc(s: rawptr, token: string, err: bufio.Scanner_Error) {
			s := cast(^Chunked_State)s

			if err != nil {
				s.cb(s.user_data, "", err)
				return
			}
			assert(len(token) == 0)

			scanner_scan(s.req._scanner, s, on_scan)
		}

		scanner_scan(s.req._scanner, s, on_scan_empty_line)
	}

	on_scan_trailer :: proc(s: rawptr, line: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		// Headers are done, success.
		if err != nil || len(line) == 0 {
			headers_delete_unsafe(&s.req.headers, "trailer")

			te_header := headers_get_unsafe(s.req.headers, "transfer-encoding")
			new_te_header := strings.trim_suffix(te_header, "chunked")

			s.req.headers.readonly = false
			headers_set_unsafe(&s.req.headers, "transfer-encoding", new_te_header)
			s.req.headers.readonly = true

			s.req._body_ok = true
			s.cb(s.user_data, strings.to_string(s.buf), nil)
			return
		}

		key, ok := header_parse(&s.req.headers, string(line))
		if !ok {
			log.infof("Invalid header when decoding chunked body: %q", string(line))
			s.cb(s.user_data, "", .Unknown)
			return
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if !header_allowed_trailer(key) {
			log.infof("Invalid trailer header received, discarding it: %q", key)
			headers_delete(&s.req.headers, key)
		}

		scanner_scan(s.req._scanner, s, on_scan_trailer)
	}

	Chunked_State :: struct {
		req:        ^Request,
		max_length: int,
		user_data:  rawptr,
		cb:         Body_Callback,

		buf:        strings.Builder,
	}

	s := new(Chunked_State, context.temp_allocator)

	s.buf.buf.allocator = context.temp_allocator

	s.req        = req
	s.max_length = max_length
	s.user_data  = user_data
	s.cb         = cb

	s.req._scanner.split = scan_lines
	scanner_scan(s.req._scanner, s, on_scan)
}
