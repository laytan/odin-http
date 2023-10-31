//+private
package client

import "core:bufio"
import "core:bytes"
import "core:c"
import "core:io"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"

import http ".."
import openssl "../openssl"

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

		endpoint.port = t.port
		if endpoint.port == 0 {
			endpoint.port = url.scheme == "https" ? 443 : 80
		}
		return
	case:
		unreachable()
	}
}

format_request :: proc(target: http.URL, request: ^Request, allocator := context.allocator) -> (buf: bytes.Buffer) {
	// Responses are on average at least 100 bytes, so lets start there, but add the body's length.
	bytes.buffer_init_allocator(&buf, 0, bytes.buffer_length(&request.body) + 100, allocator)

	http.requestline_write(
		bytes.buffer_to_stream(&buf),
		{method = request.method, target = target, version = http.Version{1, 1}},
	)

	if !http.headers_has_unsafe(request.headers, "content-length") {
		buf_len := bytes.buffer_length(&request.body)
		if buf_len == 0 {
			bytes.buffer_write_string(&buf, "content-length: 0\r\n")
		} else {
			bytes.buffer_write_string(&buf, "content-length: ")

			// Make sure at least 20 bytes are there to write into, should be enough for the content length.
			bytes.buffer_grow(&buf, buf_len + 20)

			// Write the length into unwritten portion.
			unwritten := http._dynamic_unwritten(buf.buf)
			l := len(strconv.itoa(unwritten, buf_len))
			assert(l <= 20)
			http._dynamic_add_len(&buf.buf, l)

			bytes.buffer_write_string(&buf, "\r\n")
		}
	}

	if !http.headers_has_unsafe(request.headers, "accept") {
		bytes.buffer_write_string(&buf, "accept: */*\r\n")
	}

	if !http.headers_has_unsafe(request.headers, "user-agent") {
		bytes.buffer_write_string(&buf, "user-agent: odin-http\r\n")
	}

	if !http.headers_has_unsafe(request.headers, "host") {
		bytes.buffer_write_string(&buf, "host: ")
		bytes.buffer_write_string(&buf, target.host)
		bytes.buffer_write_string(&buf, "\r\n")
	}

	for header, value in request.headers._kv {
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

			if i != len(request.cookies) - 1 {
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

SSL_Communication :: struct {
	socket: net.TCP_Socket,
	ssl:    ^openssl.SSL,
	ctx:    ^openssl.SSL_CTX,
}

Communication :: union {
	net.TCP_Socket, // HTTP.
	SSL_Communication, // HTTPS.
}

parse_response :: proc(socket: Communication, allocator := context.allocator) -> (res: Response, err: Error) {
	res._socket = socket

	stream: io.Stream
	switch comm in socket {
	case net.TCP_Socket:
		stream = tcp_stream(comm)
	case SSL_Communication:
		stream = ssl_tcp_stream(comm.ssl)
	}

	stream_reader := io.to_reader(stream)
	scanner: bufio.Scanner
	bufio.scanner_init(&scanner, stream_reader, allocator)

	http.headers_init(&res.headers, allocator)

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

	res.status, ok = http.status_from_string(rline_str[si + 1:])
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
			cookie_str := http.headers_get_unsafe(res.headers, "set-cookie")
			http.headers_delete_unsafe(&res.headers, "set-cookie")
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

	res.headers.readonly = true

	res._body = scanner
	return res, nil
}

ssl_tcp_stream :: proc(sock: ^openssl.SSL) -> (s: io.Stream) {
	s.data = sock
	s.procedure = _ssl_stream_proc
	return s
}

@(private)
_ssl_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read})
	case .Read:
		ssl := cast(^openssl.SSL)stream_data
		ret := openssl.SSL_read(ssl, raw_data(p), c.int(len(p)))
		if ret <= 0 {
			return 0, .Unexpected_EOF
		}

		return i64(ret), nil
	case:
		err = .Empty
	}
	return
}

// Wraps a tcp socket with a stream.
tcp_stream :: proc(sock: net.TCP_Socket) -> (s: io.Stream) {
	s.data = rawptr(uintptr(sock))
	s.procedure = _socket_stream_proc
	return s
}

@(private)
_socket_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read})
	case .Read:
		sock := net.TCP_Socket(uintptr(stream_data))
		received, recv_err := net.recv_tcp(sock, p)
		n = i64(received)

		#partial switch ex in recv_err {
		case net.TCP_Recv_Error:
			#partial switch ex {
			case .None:
				err = .None
			case .Shutdown, .Not_Connected, .Aborted, .Connection_Closed, .Host_Unreachable, .Timeout:
				log.errorf("unexpected error reading tcp: %s", ex)
				err = .Unexpected_EOF
			case:
				log.errorf("unexpected error reading tcp: %s", ex)
				err = .Unknown
			}
		case nil:
			err = .None
		case:
			assert(false, "recv_tcp only returns TCP_Recv_Error or nil")
		}
	case:
		err = .Empty
	}
	return
}
