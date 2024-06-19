//+build !js
//+private
package http

import intr "base:intrinsics"

import      "core:bufio"
import      "core:log"
import      "core:mem"
import      "core:net"
import      "core:os"
import      "core:strconv"
import      "core:strings"
import      "core:slice"

import      "dns"
import      "nbio"

_client_init :: proc(c: ^Client, io: ^nbio.IO, allocator := context.allocator) -> bool {
	c.allocator = allocator
	c.io = io
	c.conns.allocator = allocator

	// NOTE: this is "blocking"
	ns_err, hosts_err, ok := dns.init_sync(&c.dnsc, c.io, allocator)
	if ns_err != nil {
		log.errorf("DNS client init: name servers error: %v", ns_err)
	}
	if hosts_err != nil {
		log.errorf("DNS client init: hosts error: %v", hosts_err)
	}
	if !ok {
		return false
	}

	if client_ssl.implemented {
		assert(client_ssl.client_create != nil)
		assert(client_ssl.client_destroy != nil)
		assert(client_ssl.connection_create != nil)
		assert(client_ssl.connection_destroy != nil)
		assert(client_ssl.connect != nil)
		assert(client_ssl.send != nil)
		assert(client_ssl.recv != nil)

		c.ssl = client_ssl.client_create()
	}

	return true
}

_client_destroy :: proc(c: ^Client) {
	context.allocator = c.allocator

	for ep, &conns in c.conns {
		#reverse for conn, i in conns {
			switch conn.state {
			case .Pending, .Failed, .Closed:
				log.debug("freeing connection")
				strings.builder_destroy(&conn.buf)
				scanner_destroy(&conn.scanner)
				free(conn)
				ordered_remove(&conns, i)
			case .Connected:
				log.debug("closing connection")
				conn.state = .Closing
				nbio.close(c.io, conn.socket, c, conn, proc(c: ^Client, conn: ^Client_Connection, ok: bool) {
					if conn.ssl != nil {
						client_ssl.connection_destroy(c.ssl, conn.ssl)
					}
					conn.state = .Closed
				})
			case .Connecting, .Requesting, .Sent_Headers, .Sent_Request, .Closing:
			}
		}

		if len(conns) <= 0 {
			delete(conns)
			delete_key(&c.conns, ep)
		}
	}

	if len(c.conns) > 0 {
		nbio.next_tick(c.io, c, _client_destroy)
		return
	}

	delete(c.conns)

	dns.destroy(&c.dnsc)

	if c.ssl != nil {
		client_ssl.client_destroy(c.ssl)
	}

	log.debug("client destroyed")
}

_response_destroy :: proc(c: ^Client, res: Client_Response) {
	context.allocator = c.allocator

	for k, v in res.headers._kv {
		delete(k)
		delete(v)
	}
	headers_destroy(res.headers)

	for cookie in res.cookies {
		delete(cookie.value)
	}
	delete(res.cookies)

	delete(res.body)
}

_Client :: struct {
    allocator: mem.Allocator,
    io:        ^nbio.IO,
	// TODO: ideally the dns client is able to be set by the user.
	// So you can run multiple clients on the same DNS client?
	dnsc:      dns.Client,
	ssl:       SSL_Client,
	conns:     map[Endpoint][dynamic]^Client_Connection,
}

Scheme :: enum {
	HTTP,
	HTTPS,
}

Endpoint :: struct {
	using net: net.Endpoint,
	scheme:    Scheme,
}

In_Flight :: struct {
	using r: Client_Request,
	c:       ^_Client,
	conn:    ^Client_Connection,
	res:     Client_Response,
	ep:      Endpoint,
	user:    rawptr,
	cb:      On_Response,
}

in_flight_destroy :: proc(r: ^In_Flight) {
	context.allocator = r.c.allocator
	free(r)
}

@(private="file")
Client_Connection :: struct {
	ep:         Endpoint,
	state:      Client_Connection_State,
    ssl:        SSL_Connection,
    socket:     net.TCP_Socket,
	buf:        strings.Builder,
	scanner:    Scanner,
	using body: Has_Body,

	will_close: bool,
}

client_connection_destroy :: proc(c: ^Client, conn: ^Client_Connection) {
	context.allocator = c.allocator
	conn.state = .Closing

	if conn.ssl != nil {
		client_ssl.connection_destroy(c.ssl, conn.ssl)
	}

	nbio.close(c.io, conn.socket, c, conn, proc(c: ^Client, conn: ^Client_Connection, ok: bool) {
		if !ok {
			log.warn("failed closing connection")
		}

		conn.state = .Closed

		conns, has_conns := &c.conns[conn.ep]
		assert(has_conns)
		idx, found := slice.linear_search(conns[:], conn)
		assert(found)
		unordered_remove(conns, idx)

		if len(conns) == 0 {
			delete(conns^)
			delete_key(&c.conns, conn.ep)
		}

		strings.builder_destroy(&conn.buf)
		scanner_destroy(&conn.scanner)
		headers_destroy(conn.headers)
		free(conn)
	})
}

@(private="file")
Client_Connection_State :: enum {
	Pending,
	Connecting,
	Connected,
	Requesting,
	Sent_Headers,
	Sent_Request,
	Closing,
	Closed,
	Failed,
}

_client_request :: proc(c: ^Client, req: Client_Request, user: rawptr, cb: On_Response) {
	host := url_parse(req.url).host
    host_or_endpoint, err := net.parse_hostname_or_endpoint(host)
    if err != nil {
		log.warnf("Invalid request URL %q: %v", req.url, err)
        cb({}, user, .Bad_URL)
        return
    }

	r := new(In_Flight, c.allocator)
	r.r = req
	r.c = c
	r.user = user
	r.cb = cb

    switch t in host_or_endpoint {
    case net.Endpoint:
		r.ep.net = t
		on_dns_resolve(r, { t.address, max(u32) }, nil)
    case net.Host:
		r.ep.port = t.port
		dns.resolve(&c.dnsc, t.hostname, r, on_dns_resolve)
    case:
        unreachable()
    }

	on_dns_resolve :: proc(r: rawptr, record: dns.Record, err: net.Network_Error) {
		r := (^In_Flight)(r)
		if err != nil {
			log.warnf("DNS resolve error for %q: %v", r.r.url, err)
			r.cb({}, r.user, .DNS)
			free(r, r.c.allocator)
			return
		}

		// Finalize endpoint
		{
			r.ep.address = record.address

			switch scheme_str := url_parse(r.url).scheme; scheme_str {
			case "http", "ws":   r.ep.scheme = .HTTP
			case "https", "wss": r.ep.scheme = .HTTPS
			case:
				switch r.ep.port {
				case 80:  r.ep.scheme = .HTTP
				case 443: r.ep.scheme = .HTTPS
				case:
					log.infof("could not reliably determine HTTP or HTTPS based on given scheme %q and port %v, defaulting to HTTP", scheme_str, r.ep.port)
				}
			}

			if r.ep.port == 0 {
				switch r.ep.scheme {
				case .HTTP:  r.ep.port = 80
				case .HTTPS: r.ep.port = 443
				case:        unreachable()
				}
			}
		}

		log.debugf("DNS of %v resolved to %v", r.url, r.ep)

		get_connection: {
			context.allocator = r.c.allocator

			conns, has_conns := &r.c.conns[r.ep]
			if !has_conns {
				conns = map_insert(&r.c.conns, r.ep, make([dynamic]^Client_Connection))
			}

			for conn in conns {
				// NOTE: might want other states too.
				if conn.state == .Connected {
					r.conn = conn
					break get_connection
				}
			}

			r.conn = new(Client_Connection)
			r.conn.ep = r.ep
			append(conns, r.conn)
		}

		connect(r)
	}

	handle_net_err :: proc(r: ^In_Flight, err: net.Network_Error, ctx := "") {
		panic("NOOOOOOOOOO")
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

		nbio.connect(r.c.io, r.ep, r, on_tcp_connect)

		on_tcp_connect :: proc(r: ^In_Flight, socket: net.TCP_Socket, err: net.Network_Error) {
			if err != nil {
				handle_net_err(r, err, "TCP connect failed")
				return
			}

			assert(r.conn.state == .Connecting)

			log.debug("TCP connection established")
			r.conn.socket = socket

			switch r.ep.scheme {
			case .HTTP:
				r.conn.state = .Connected
				on_connected(r, nil)
			case .HTTPS:
				if !client_ssl.implemented || r.c.ssl == nil {
					panic("HTTP client can't serve HTTPS request without an SSL implementation, set it using `set_client_ssl`")
				}

				host := url_parse(r.url).host
				chost := strings.clone_to_cstring(host, r.c.allocator)
				defer delete(chost)
				r.conn.ssl = client_ssl.connection_create(r.c.ssl, socket, chost)

				ssl_connect(r, nil)

				ssl_connect :: proc(r: ^In_Flight, _: nbio.Poll_Event) {
					switch client_ssl.connect(r.conn.ssl) {
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
	}

	on_connected :: proc(r: ^In_Flight, err: net.Network_Error) {
		if err != nil {
			handle_net_err(r, err, "SSL connect failed")
			return
		}

		assert(r.conn.state == .Connected)

		// Prepare requestline/headers
		{
			buf := &r.conn.buf
			strings.builder_reset(buf)
			s := strings.to_stream(buf)

			ws :: strings.write_string

			err := requestline_write(s, { method = r.method, target = r.url, version = {1, 1} })
			assert(err == nil) // Only really can be an allocator error.

			if !headers_has_unsafe(r.headers, "content-length") {
				buf_len := len(r.body)
				if buf_len == 0 {
					ws(buf, "content-length: 0\r\n")
				} else {
					ws(buf, "content-length: ")

					// Make sure at least 20 bytes are there to write into, should be enough for the content length.
					strings.builder_grow(buf, buf_len + 20)

					// Write the length into unwritten portion.
					unwritten := dynamic_unwritten(buf.buf)
					l := len(strconv.itoa(unwritten, buf_len))
					assert(l <= 20)
					dynamic_add_len(&buf.buf, l)

					ws(buf, "\r\n")
				}
			}

			if !headers_has_unsafe(r.headers, "accept") {
				ws(buf, "accept: */*\r\n")
			}

			if !headers_has_unsafe(r.headers, "user-agent") {
				ws(buf, "user-agent: odin-http\r\n")
			}

			if !headers_has_unsafe(r.headers, "host") {
				ws(buf, "host: ")
				ws(buf, url_parse(r.url).host)
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
		switch r.ep.scheme {
		case .HTTP:  send_http_request(r)
		case .HTTPS: send_https_request(r)
		}
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
			case .Failed:       on_sent_request(r, net.TCP_Send_Error.Aborted)
			case .Sent_Headers: on_sent_request(r, err)
			case:               unreachable()
			}
		}
	}

	send_https_request :: proc(r: ^In_Flight) {
		ssl_write_req(r, nil)

		ssl_write_req :: proc(r: ^In_Flight, _: nbio.Poll_Event) {
			switch n, res := client_ssl.send(r.conn.ssl, r.conn.buf.buf[:]); res {
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

			switch n, res := client_ssl.send(r.conn.ssl, r.body); res {
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
			handle_net_err(r, err, "send request failed")
			return
		}

		log.debug("request has been sent, receiving response")

		r.conn._scanner = &r.conn.scanner
		scanner_reset(&r.conn.scanner)
		scanner_init(&r.conn.scanner, r, scanner_recv)

		r.conn.will_close = false
		r.conn._body_ok = nil

		scanner_recv :: proc(r: rawptr, buf: []byte, s: ^Scanner, callback: On_Scanner_Read) {
			r := (^In_Flight)(r)

			// TODO: use the timeout.

			switch r.ep.scheme {
			case .HTTP:
				log.debug("executing non-SSL read")
				nbio.recv(
					r.c.io, r.conn.socket, buf, s, callback,
					proc(s: ^Scanner, callback: On_Scanner_Read, n: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
						callback(s, n, err)
					},
				)
			case .HTTPS:
				ssl_recv(r, buf, callback, nil)

				ssl_recv :: proc(r: ^In_Flight, buf: []byte, callback: On_Scanner_Read, _: nbio.Poll_Event) {
					log.debug("executing SSL recv")
					switch n, res := client_ssl.recv(r.conn.ssl, buf); res {
					case .None:
						log.debugf("Successfully received %m from the connection", n)
						callback(&r.conn.scanner, n, nil)
					case .Want_Read:
						log.debug("SSL read want read")
						nbio.poll(r.c.io, os.Handle(r.conn.socket), .Read, false, r, buf, callback, ssl_recv)
					case .Want_Write:
						log.debug("SSL read want write")
						nbio.poll(r.c.io, os.Handle(r.conn.socket), .Write, false, r, buf, callback, ssl_recv)
					case .Shutdown:
						log.error("read failed, connection is closed")
						callback(&r.conn.scanner, 0, net.TCP_Recv_Error.Connection_Closed)
					case: fallthrough
					case .Fatal:
						log.error("read failed due to unknown Fatal reason")
						callback(&r.conn.scanner, 0, net.TCP_Recv_Error.Aborted)
					}
				}
			}
		}

		log.debug("scanner scannnn")
		scanner_scan(&r.conn.scanner, r, on_rline1)

		handle_scanner_err :: proc(r: ^In_Flight, err: bufio.Scanner_Error, ctx := "") {
			panic("NOOOOOOOOOO")
		}

		//
		handle_bad_response :: proc(r: ^In_Flight, ctx := "") {
			log.warnf("bad response: %s", ctx)

			// free everything, close connection,
		}

		on_rline1 :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				handle_scanner_err(r, err, "reading request-line")
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
				scanner_scan(&r.conn.scanner, r, on_rline2)
				return
			}

			on_rline2(r, token, nil)
		}

		on_rline2 :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				handle_scanner_err(r, err, "reading request-line attempt 2")
				return
			}

			si := strings.index_byte(token, ' ')
			if si == -1 && si != len(token)-1 {
				handle_bad_response(r, "response line missing a space")
				return
			}

			version, ok := version_parse(token[:si])
			if !ok || version.major != 1 {
				handle_bad_response(r, "invalid HTTP version in response")
				return
			}

			// HTTP 1.0, no persistent connections
			if version.minor == 0 {
				r.conn.will_close = true
			}

			r.res.status, ok = status_from_string(token[si+1:])
			if !ok {
				handle_bad_response(r, "invalid status code in response")
				return
			}

			log.debugf("got valid response line %q, parsing headers...", token)

			// TODO: max header size.

			headers_init(&r.headers, r.c.allocator)

			scanner_scan(&r.conn.scanner, r, on_header_line)
		}

		on_header_line :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				handle_scanner_err(r, err, "failed reading header line")
				return
			}

			// NOTE: any errors should destroy all allocations.

			// First empty line means end of headers.
			if len(token) == 0 {
				on_headers_end(r)
				return
			}

			key, ok := header_parse(&r.conn.headers, token, r.c.allocator)
			if !ok {
				handle_bad_response(r, "invalid header line")
				return
			}

			if key == "set-cookie" {
				cookie_str := headers_get_unsafe(r.conn.headers, "set-cookie")
				headers_delete_unsafe(&r.conn.headers, "set-cookie")
				delete(key, r.c.allocator)

				cookie, cok := cookie_parse(cookie_str)
				if !cok {
					handle_bad_response(r, "invalid cookie")
					return
				}

				append(&r.res.cookies, cookie)
			}

			log.debugf("parsed valid header %q", token)
			scanner_scan(&r.conn.scanner, r, on_header_line)
		}

		on_headers_end :: proc(r: ^In_Flight) {
			if !headers_sanitize(&r.conn.headers) {
				handle_bad_response(r, "invalid combination of headers")
				return
			}

			// TODO: configurable max length.
			body(&r.conn.body, -1, r, on_body)
		}

		on_body :: proc(r: rawptr, body: string, err: Body_Error) {
			r := (^In_Flight)(r)
			if err != nil {
				handle_scanner_err(r, err)
				return
			}

			// TODO: determine based on response status and headers if we can keep the connection
			// alive, if so, put the connection on a free list.

			r.conn.state = .Connected

			r.res.headers = r.conn.headers
			r.res.headers.readonly = true

			r.conn.headers = {}

			r.res.body = make([]byte, len(body), r.c.allocator)
			copy(r.res.body, body)

			r.cb(r.res, r.user, nil)

			free(r, r.c.allocator)
		}
	}
}
