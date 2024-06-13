//+build !js
package client

import intr "base:intrinsics"
import "core:bufio"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import      "dns"
import http ".."
import nbio "../nbio/poly"

init :: proc(c: Client, io: ^nbio.IO, dnsc: ^dns.Client, ssl: SSL = default_ssl_implementation, allocator := context.allocator) {
	c := (^_Client)(c)

	c.allocator = allocator
	c.io = io
	c.dnsc = dnsc
	c.ssl = ssl

	if ssl.implemented {
		assert(ssl.client_create != nil)
		assert(ssl.connection_create != nil)
		assert(ssl.connect != nil)
		assert(ssl.send != nil)
		assert(ssl.recv != nil)

		c.ssl_client = ssl.client_create()
	}
}

@(private)
_Client :: struct {
    allocator: mem.Allocator,

    io: ^nbio.IO,

	dnsc: ^dns.Client,

	ssl: SSL,
	ssl_client: SSL_Client,

	conns: map[net.Endpoint][dynamic]^Connection,
}

@(private)
In_Flight :: struct {
	using r: Request,
	c:       ^_Client,
	conn:    ^Connection,
	res:     Response,
	user:    rawptr,
	cb:      On_Response,
}

@(private)
Connection :: struct {
	ep:         net.Endpoint,
	state:      Connection_State,
    ssl:        SSL_Connection,
    socket:     net.TCP_Socket,
	buf:        strings.Builder,
	bscanner:   http.Scanner,
	using body: http.Has_Body,
}

@(private)
Connection_State :: enum {
	Pending,
	Connecting,
	Connected,
	Requesting,
	Sent_Headers,
	Sent_Request,
	Failed,
}


@(private)
_request :: proc(c: Client, req: Request, user: rawptr, cb: On_Response) {
	c := (^_Client)(c)

    host_or_endpoint, err := net.parse_hostname_or_endpoint(req.url.host)
    if err != nil {
		log.warnf("Invalid request URL %q: %v", req.url, err)
        cb({}, user, err)
        return
    }

	r := new(In_Flight, c.allocator)
	r.r = req
	r.c = c
	r.user = user
	r.cb = cb

    switch t in host_or_endpoint {
    case net.Endpoint:
		on_dns_resolve(r, { t.address, max(u32) }, nil)
    case net.Host:
		dns.resolve(c.dnsc, t.hostname, r, on_dns_resolve)
    case:
        unreachable()
    }

	on_dns_resolve :: proc(r: rawptr, record: dns.Record, err: net.Network_Error) {
		r := (^In_Flight)(r)
		if err != nil {
			log.warnf("DNS resolve error for %q: %v", r.r.url, err)
			r.cb({}, r.user, err)
			free(r, r.c.allocator)
			return
		}

		port := r.url.scheme == "https" ? 443 : 80
		endpoint := net.Endpoint{ record.address, port }

		log.debugf("DNS of %q resolved to %v", r.url.host, endpoint)

		if endpoint not_in r.c.conns {
			r.c.conns[endpoint] = {}
		}

		conns := &r.c.conns[endpoint]
		conn, has_conn := pop_safe(conns)
		if !has_conn {
			log.debug("no ready connections for that endpoint")
			conn = new(Connection, r.c.allocator)
		}

		r.conn = conn
		r.conn.ep = endpoint
		connect(r)
	}

	connect :: proc(r: ^In_Flight) {
		// TODO: connected state, but actually disconnected when we try write
		#partial switch r.conn.state {
		case:
			log.panicf("connect: invalid state: %v", r.conn.state)
		case .Connected:
			on_connected(r, nil)
			return
		case .Pending:
		}

		r.conn.state = .Connecting

		log.debug("connecting to endpoint")

		nbio.connect(r.c.io, r.conn.ep, r, on_tcp_connect)

		on_tcp_connect :: proc(r: ^In_Flight, socket: net.TCP_Socket, err: net.Network_Error) {
			if err != nil {
				log.errorf("TCP connect failed: %v", err)
				r.cb({}, r.user, err)
				free(r.conn, r.c.allocator)
				free(r, r.c.allocator)
				return
			}

			assert(r.conn.state == .Connecting)

			log.debug("TCP connection established")
			r.conn.socket = socket

			if r.conn.ep.port != 443 {
				r.conn.state = .Connected
				on_connected(r, nil)
				return
			}

			if !r.c.ssl.implemented {
				panic("HTTP client can't serve HTTPS request without an SSL implementation either given on `init` or set using `set_default_ssl_implementation`")
			}

			chost := strings.clone_to_cstring(r.url.host, r.c.allocator)
			defer delete(chost)
			r.conn.ssl = r.c.ssl.connection_create(r.c.ssl_client, socket, chost)

			ssl_connect(r, nil)

			ssl_connect :: proc(r: ^In_Flight, _: nbio.Poll_Event) {
				switch r.c.ssl.connect(r.conn.ssl) {
				case .None:
					log.debug("SSL connection established")
					r.conn.state = .Connected
					on_connected(r, nil)
				case .Want_Read:
					log.debug("SSL connect want read")
					nbio.poll(r.c.io, os.Handle(r.conn.socket), .Read,  false, r, ssl_connect)
				case .Want_Write:
					log.debug("SSL connect want write")
					nbio.poll(r.c.io, os.Handle(r.conn.socket), .Write, false, r, ssl_connect)
				case .Shutdown:
					log.error("SSL connect error: Shutdown")
					on_connected(r, net.Dial_Error.Refused)
				case: fallthrough
				case .Fatal:
					log.error("SSL connect error: Fatal")
					on_connected(r, net.Dial_Error.Refused)
				}
			}
		}
	}

	on_connected :: proc(r: ^In_Flight, err: net.Network_Error) {
		if err != nil {
			nbio.close(r.c.io, r.conn.socket)
			r.cb({}, r.user, err)
			free(r.conn, r.c.allocator)
			free(r, r.c.allocator)
			return
		}

		assert(r.conn.state == .Connected)

		// Prepare requestline/headers
		{
			buf := &r.conn.buf
			strings.builder_reset(buf)
			s := strings.to_stream(buf)

			ws :: strings.write_string

			err := http.requestline_write(s, { method = r.method, target = r.url, version = {1, 1} })
			assert(err == nil) // Only really can be an allocator error.

			if !http.headers_has_unsafe(r.headers, "content-length") {
				buf_len := len(r.body)
				if buf_len == 0 {
					ws(buf, "content-length: 0\r\n")
				} else {
					ws(buf, "content-length: ")

					// Make sure at least 20 bytes are there to write into, should be enough for the content length.
					strings.builder_grow(buf, buf_len + 20)

					// Write the length into unwritten portion.
					unwritten := http._dynamic_unwritten(buf.buf)
					l := len(strconv.itoa(unwritten, buf_len))
					assert(l <= 20)
					http._dynamic_add_len(&buf.buf, l)

					ws(buf, "\r\n")
				}
			}

			if !http.headers_has_unsafe(r.headers, "accept") {
				ws(buf, "accept: */*\r\n")
			}

			if !http.headers_has_unsafe(r.headers, "user-agent") {
				ws(buf, "user-agent: odin-http\r\n")
			}

			if !http.headers_has_unsafe(r.headers, "host") {
				ws(buf, "host: ")
				ws(buf, r.url.host)
				ws(buf, "\r\n")
			}

			for header, value in r.headers._kv {
				ws(buf, header)
				ws(buf, ": ")
				ws(buf, value)
				ws(buf, "\r\n")
			}

			if len(r.cookies) > 0 {
				ws(buf, "cookie: ")

				for cookie, i in r.cookies {
					ws(buf, cookie.name)
					ws(buf, "=")
					ws(buf, cookie.value)

					if i != len(r.cookies) - 1 {
						ws(buf, "; ")
					}
				}

				ws(buf, "\r\n")
			}

			ws(buf, "\r\n")
		}

		r.conn.state = .Requesting

		// HTTP request.
		if r.conn.ep.port != 443 {
			send_http_request(r)
			return
		}

		// HTTPS request.
		send_https_request(r)
	}

	send_http_request :: proc(r: ^In_Flight) {
		assert(r.conn.state == .Requesting)

		log.debugf("Sending HTTP request:\n%v%v", string(r.conn.buf.buf[:]), string(r.body))
		nbio.send_all(r.c.io, r.conn.socket, r.conn.buf.buf[:], r, on_sent_req)
		if len(r.body) > 0 {
			nbio.send_all(r.c.io, r.conn.socket, r.body, r, on_sent_body)
		}

		on_sent_req :: proc(r: ^In_Flight, sent: int, err: net.Network_Error) {
			assert(r.conn.state == .Requesting)
			r.conn.state = .Sent_Headers if err == nil else .Failed

			if len(r.body) == 0 {
				on_sent_request(r, err)
			}
		}

		on_sent_body :: proc(r: ^In_Flight, sent: int, err: net.Network_Error) {
			#partial switch r.conn.state {
			case .Failed:
				on_sent_request(r, net.TCP_Send_Error.Aborted)
				return
			case: unreachable()
			case .Sent_Headers:
				on_sent_request(r, err)
			}
		}
	}

	send_https_request :: proc(r: ^In_Flight) {
		ssl_write_req(r, nil)

		ssl_write_req :: proc(r: ^In_Flight, _: nbio.Poll_Event) {
			switch n, res := r.c.ssl.send(r.conn.ssl, r.conn.buf.buf[:]); res {
			case .None:
				log.debugf("Successfully written request line and headers of %m to connection", n)
				r.conn.state = .Sent_Headers
				ssl_write_body(r, nil)
			case .Want_Read:
				log.debug("SSL write want read")
				nbio.poll(r.c.io, os.Handle(r.conn.socket), .Read, false, r, ssl_write_req)
			case .Want_Write:
				log.debug("SSL write want write")
				nbio.poll(r.c.io, os.Handle(r.conn.socket), .Write, false, r, ssl_write_req)
			case .Shutdown:
				log.error("write failed, connection is closed")
				on_sent_request(r, net.TCP_Send_Error.Connection_Closed)
			case: fallthrough
			case .Fatal:
				log.errorf("write failed due to unknown Fatal reason")
				on_sent_request(r, net.TCP_Send_Error.Aborted)
			}
		}

		ssl_write_body :: proc(r: ^In_Flight, _: nbio.Poll_Event) {
			assert(r.conn.state == .Sent_Headers)

			log.debugf("Writing body of %m to connection", len(r.body))

			if len(r.body) == 0 {
				r.conn.state = .Sent_Request
				on_sent_request(r, nil)
				return
			}

			switch n, res := r.c.ssl.send(r.conn.ssl, r.body); res {
			case .None:
				log.debugf("Successfully written body of %m to connection", n)
				r.conn.state = .Sent_Request
				on_sent_request(r, nil)
			case .Want_Read:
				log.debug("SSL write want read")
				nbio.poll(r.c.io, os.Handle(r.conn.socket), .Read, false, r, ssl_write_body)
			case .Want_Write:
				log.debug("SSL write want write")
				nbio.poll(r.c.io, os.Handle(r.conn.socket), .Write, false, r, ssl_write_body)
			case .Shutdown:
				log.error("write failed, connection is closed")
				on_sent_request(r, net.TCP_Send_Error.Connection_Closed)
			case: fallthrough
			case .Fatal:
				log.error("write failed due to unknown Fatal reason")
				on_sent_request(r, net.TCP_Send_Error.Aborted)
			}
		}
	}

	on_sent_request :: proc(r: ^In_Flight, err: net.Network_Error) {
		if err != nil {
			r.conn.state = .Failed
			log.errorf("send request failed: %v", err)
			r.cb({}, r.user, err)
			// TODO: free
			return
		}

		log.debug("request has been sent, receiving response")

		r.conn.scanner = &r.conn.bscanner
		http.scanner_reset(r.conn.scanner)
		http.scanner_init(r.conn.scanner, r, scanner_recv)

		scanner_recv :: proc(r: rawptr, buf: []byte, s: ^http.Scanner, callback: http.On_Scanner_Read) {
			r := (^In_Flight)(r)

			if r.conn.ep.port != 443 {
				log.debug("executing non-SSL read")
				nbio.recv(
					r.c.io, r.conn.socket, buf, s, callback,
					proc(s: ^http.Scanner, callback: http.On_Scanner_Read, n: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
						callback(s, n, err)
					},
				)
				return
			}

			ssl_recv(r, buf, callback, nil)

			ssl_recv :: proc(r: ^In_Flight, buf: []byte, callback: http.On_Scanner_Read, _: nbio.Poll_Event) {
				log.debug("executing SSL recv")
				switch n, res := r.c.ssl.recv(r.conn.ssl, buf); res {
				case .None:
					log.debugf("Successfully received %m from the connection", n)
					callback(r.conn.scanner, n, nil)
				case .Want_Read:
					log.debug("SSL read want read")
					nbio.poll(r.c.io, os.Handle(r.conn.socket), .Read, false, r, buf, callback, ssl_recv)
				case .Want_Write:
					log.debug("SSL read want write")
					nbio.poll(r.c.io, os.Handle(r.conn.socket), .Write, false, r, buf, callback, ssl_recv)
				case .Shutdown:
					log.error("read failed, connection is closed")
					callback(r.conn.scanner, 0, net.TCP_Recv_Error.Connection_Closed)
				case: fallthrough
				case .Fatal:
					log.error("read failed due to unknown Fatal reason")
					callback(r.conn.scanner, 0, net.TCP_Recv_Error.Aborted)
				}
			}
		}

		log.debug("scanner scannnn")
		http.scanner_scan(r.conn.scanner, r, on_rline1)

		handle_scanner_err :: proc(r: ^In_Flight, err: bufio.Scanner_Error) {
			panic("NOOOOOOOOOO")
		}

		handle_net_err :: proc(r: ^In_Flight, err: net.Network_Error) {
			panic("NOOOOOOOOOO")
		}

		on_rline1 :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				log.errorf("error during read of first response line: %v", err)
				handle_scanner_err(r, err)
				return
			}

			log.debug("got response line")

			// NOTE: this is RFC advice for servers, but seems sensible here too.
			//
			// In the interest of robustness, a server that is expecting to receive
			// and parse a request-line SHOULD ignore at least one empty line (CRLF)
			// received prior to the request-line.
			if len(token) == 0 {
				log.debug("first response line is empty, skipping in interest of robustness")
				http.scanner_scan(r.conn.scanner, r, on_rline2)
				return
			}

			on_rline2(r, token, nil)
		}

		on_rline2 :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				log.errorf("error during read of first response line: %v", err)
				handle_scanner_err(r, err)
				return
			}

			si := strings.index_byte(token, ' ')
			if si == -1 && si != len(token)-1 {
				log.errorf("invalid response line %q missing a space", token)
				handle_net_err(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
				return
			}

			version, ok := http.version_parse(token[:si])
			if !ok || version.major != 1 {
				log.errorf("invalid HTTP version %q on response line %q", token[:si], token)
				handle_net_err(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
				return
			}

			r.res.status, ok = http.status_from_string(token[si+1:])
			if !ok {
				log.errorf("invalid status %q on response line %q", token[si+1:], token)
				handle_net_err(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
				return
			}

			log.debugf("got valid response line %q, parsing headers...", token)
			http.scanner_scan(r.conn.scanner, r, on_header_line)
		}

		on_header_line :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				log.errorf("error during read of header line: %v", err)
				handle_scanner_err(r, err)
				return
			}

			// First empty line means end of headers.
			if len(token) == 0 {
				on_headers_end(r)
				return
			}

			key, ok := http.header_parse(&r.conn.headers, token, /*r.allocator*/)
			if !ok {
				log.errorf("invalid response header line %q", token)
				handle_net_err(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
				return
			}

			if key == "set-cookie" {
				cookie_str := http.headers_get_unsafe(r.conn.headers, "set-cookie")
				http.headers_delete_unsafe(&r.conn.headers, "set-cookie")
				delete(key, /*r.allocator*/)

				cookie, cok := http.cookie_parse(cookie_str, /*r.allocator*/)
				if !cok {
					log.errorf("invalid cookie %q in header %q", cookie_str, token)
					handle_net_err(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
					return
				}

				append(&r.res.cookies, cookie)
			}

			log.debugf("parsed valid header %q", token)
			http.scanner_scan(r.conn.scanner, r, on_header_line)
		}

		on_headers_end :: proc(r: ^In_Flight) {
			if !http.headers_validate(&r.conn.headers) {
				log.errorf("invalid headers %v", r.conn.headers._kv)
				handle_net_err(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
				return
			}

			// TODO: configurable max length.
			http.body(&r.conn.body, -1, r, on_body)
		}

		on_body :: proc(r: rawptr, body: string, err: http.Body_Error) {
			r := (^In_Flight)(r)
			if err != nil {
				handle_scanner_err(r, err)
				return
			}

			r.res.headers = r.conn.headers
			r.res.headers.readonly = true

			r.res.body = make([]byte, len(body))
			copy(r.res.body, body)

			// TODO: clean it all up

			r.cb(r.res, r.user, nil)
		}
	}

}
