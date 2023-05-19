//+private
package client

import "core:bufio"
import "core:bytes"
import "core:io"
import "core:net"
import "core:strconv"
import "core:strings"

import http ".."

parse_endpoint :: proc(target: string) -> (url: http.URL, endpoint: net.Endpoint, err: net.Network_Error) {
	url = http.url_parse(target)
	host_or_endpoint := net.parse_hostname_or_endpoint(url.host) or_return

	switch t in host_or_endpoint {
	case net.Endpoint:
		endpoint = t
		return
	case net.Host:
		ep4, ep6 := net.resolve(t.hostname) or_return
		endpoint = ep4 if ep4.address != nil else ep6
		endpoint.port = t.port == 0 ? 80 : t.port
		return
	case: panic("unreachable")
	}
}

// TODO: maybe net.percent_encode.
request_path :: proc(target: http.URL, allocator := context.allocator) -> (rq_path: string) {
	res := strings.builder_make(0, len(target.path), allocator)
	strings.write_string(&res, target.path)
	if target.path == "" {
		strings.write_byte(&res, '/')
	}

	if len(target.queries) > 0 {
		strings.write_byte(&res, '?')

		i := 0
		for key, value in target.queries {
			strings.write_string(&res, key)
			if value != "" {
				strings.write_byte(&res, '=')
				strings.write_string(&res, value)
			}

			if i != len(target.queries) -1 {
				strings.write_byte(&res, '&')
			}

			i += 1
		}
	}

	return strings.to_string(res)
}

format_request :: proc(target: http.URL, request: ^Request, allocator := context.allocator) -> (buf: bytes.Buffer) {
	// Responses are on average at least 100 bytes, so lets start there, but add the body's length.
	bytes.buffer_init_allocator(&buf, 0, bytes.buffer_length(&request.body) + 100, allocator)

	rp := request_path(target)
	defer delete(rp)

	http.requestline_write(http.Requestline{
		method  = request.method,
		target  = rp,
		version = http.Version{1, 1},
	}, &buf, allocator)

	if "content-length" not_in request.headers {
		buf_len := bytes.buffer_length(&request.body)
		if buf_len == 0 {
			request.headers["content-length"] = "0"
		} else {
			buf: [32]byte
			request.headers["content-length"] = strconv.itoa(buf[:], buf_len)

			// Delete the header so it is not pointing to invalid memory after we return.
			// It is only needed here to write into the buf.
			defer delete_key(&request.headers, "content-length")
		}
	}

	if "accept" not_in request.headers {
		request.headers["accept"] = "*/*"
	}

	if "user-agent" not_in request.headers {
		request.headers["user-agent"] = "odin-http"
	}

	if "host" not_in request.headers {
		request.headers["host"] = target.host
	}

	for header, value in request.headers {
		bytes.buffer_write_string(&buf, header)
		bytes.buffer_write_string(&buf, ": ")

		// Escape newlines in headers, if we don't, an attacker can find an endpoint
		// that returns a header with user input, and inject headers into the response.
		esc_value, was_allocation := strings.replace_all(value, "\n", "\\n", allocator)
		defer if was_allocation do delete(esc_value)

		bytes.buffer_write_string(&buf, esc_value)
		bytes.buffer_write_string(&buf, "\r\n")
	}

	if len(request.cookies) > 0 {
		bytes.buffer_write_string(&buf, "cookie: ")

		for cookie, i in request.cookies {
			bytes.buffer_write_string(&buf, cookie.name)
			bytes.buffer_write_byte(&buf, '=')
			bytes.buffer_write_string(&buf, cookie.value)

			if i != len(request.cookies) -1 {
				bytes.buffer_write_string(&buf, "; ")
			}
		}

		bytes.buffer_write_string(&buf, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	bytes.buffer_write_string(&buf, "\r\n")

	bytes.buffer_write(&buf, bytes.buffer_to_bytes(&request.body))
	return
}

parse_response :: proc(socket: net.TCP_Socket, allocator := context.allocator) -> (res: Response, err: Error) {
	res._socket = socket

	stream := http.tcp_stream(socket)
	stream_reader := io.to_reader(stream)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, stream_reader, allocator)

	res.headers = make(http.Headers, 3, allocator)

	if !bufio.scanner_scan(&scanner) {
		err = bufio.scanner_error(&scanner)
		return
	}

	rline_str := bufio.scanner_text(&scanner)
	si := strings.index_byte(rline_str, ' ')

	version, ok := http.version_parse(rline_str[:si])
	if !ok {
		err = Request_Error.Invalid_Response_HTTP_Version
		return
	}

	// Might need to support more versions later.
	if version.major != 1 {
		err = Request_Error.Invalid_Response_HTTP_Version
		return
	}

	res.status, ok = http.status_from_string(rline_str[si+1:])
	if !ok {
		err = Request_Error.Invalid_Response_Method
		return
	}

	for {
		if !bufio.scanner_scan(&scanner) {
			err = bufio.scanner_error(&scanner)
			return
		}

		line := bufio.scanner_text(&scanner)
		// Empty line means end of headers.
		if line == "" do break

		key, ok := http.header_parse(&res.headers, line, allocator)
		if !ok {
			err = Request_Error.Invalid_Response_Header
			return
		}

		if key == "set-cookie" {
			cookie_str := res.headers["set-cookie"]
			delete_key(&res.headers, key)
			delete(key)

			cookie, ok := http.cookie_parse(cookie_str, allocator)
			if !ok {
				err = Request_Error.Invalid_Response_Cookie
				return
			}

			append(&res.cookies, cookie)
		}
	}

	if !http.headers_validate(&res.headers) {
		err = Request_Error.Invalid_Response_Header
		return
	}

	res._body = scanner
	return res, nil
}
