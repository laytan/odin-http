// package client provides a HTTP/1.1 client.
package client

import intr "base:intrinsics"
import "core:bufio"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import http ".."
import nbio "../nbio/poly"
import ssl  "../openssl"

ssl_verify_ptr :: #force_inline proc(ptr: $T, loc := #caller_location) where intr.type_is_pointer(T) {
    if intr.expect(ptr == nil, false) {
        logger := context.logger
        ssl.errors_print_to_log(&logger)
        panic("openSSL returned nil pointer", loc)
    }
}

// TODO: max response line/header/body sizes.

Client :: struct {
    allocator: mem.Allocator,

	// NOTE: these are allocated inside openSSL, nothing to do with the given allocator unfortunately.
    io:  ^nbio.IO,
    ctx: ^ssl.SSL_CTX,

    // TODO: DNS cache.
    // dns: map[string]net.Endpoint,

    // TODO: should this hold all the current requests?
}

// The thing is right, http 1 needs sequential messaging on the socket, ie send request -> receive response -> send request.
// So it doesn't really make much sense to decouple the connection from the
// request/response structs, maybe we can use a linked list type thing where
// you can queue a bunch of requests on a connection?
//
// But then we'd also want to be able to spin up multiple connections to a host
// and send requests that way.
//
// A good middleground is probably allowing users to drop lower and create more
// connections themselves, and orchestrate the requests over them. But by default
// have a linked list of requests to send over a connection.

Connection_State :: enum {
	Pending,
	Connecting,
	Connected,
	Failed,
}

Connection :: struct {
    allocator: mem.Allocator,

	client:    ^Client,

	state:     Connection_State,
	host:      cstring,
	endpoint:  net.Endpoint,
	scheme:    Scheme,
    ssl:       ^ssl.SSL,
    socket:    net.TCP_Socket,

    request:   ^Request, // Linked list of requests to execute asynchronously.
}

Request :: struct {
    allocator: mem.Allocator,

    conn: ^Connection,

    next: ^Request,

	on_response: On_Response,
	user_data:   rawptr,

    path:    string,
    method:  http.Method,
    headers: http.Headers,
    cookies: [dynamic]http.Cookie,
    body:    strings.Builder,
    buf:     strings.Builder, // TODO: this can probably be removed from the struct.
    res:     Response,
}

Response :: struct {
	scanner: http.Scanner, // TODO: move into connection.

    status:  http.Status,
    headers: http.Headers,
    cookies: [dynamic]http.Cookie,
}

init :: proc {
	client_init,
	connection_init,
	request_init,
}

destroy :: proc {
	client_destroy,
	connection_destroy,
	request_destroy,
}

client_init :: proc(c: ^Client, io: ^nbio.IO, allocator := context.allocator) {
	c.allocator = allocator
	c.io = io

    method := ssl.TLS_client_method()
    ssl_verify_ptr(method)

    c.ctx = ssl.SSL_CTX_new(method)
    ssl_verify_ptr(c.ctx)
}

client_make :: proc(io: ^nbio.IO, allocator := context.allocator) -> (client: Client) {
    init(&client, io, allocator)
	return
}

client_destroy :: proc(client: ^Client) {
	log.warn("TODO", #procedure)
}

Scheme :: enum {
	From_Target,
	HTTP,
	HTTPS,
}

connection_init :: proc(conn: ^Connection, client: ^Client, target: string, scheme := Scheme.From_Target, allocator := context.allocator) -> (ok: bool) {
	conn.allocator = allocator
	conn.client = client
	conn.scheme = scheme

	url := http.url_parse(target)
	if conn.scheme == .From_Target {
		switch url.scheme {
		case "https":
			conn.scheme = .HTTPS
		case:
			log.warnf("given target %q does not have a `http://` or `https://` prefix to infer the type of connection from, either add a prefix or set the `scheme` parameter, falling back to http.", target)
			fallthrough
		case "http":
			conn.scheme = .HTTP
		}
	}

	conn.host = strings.clone_to_cstring(url.host, allocator)

	conn.ssl = ssl.SSL_new(client.ctx)
	ssl_verify_ptr(conn.ssl)

    if ssl.SSL_set_tlsext_host_name(conn.ssl, conn.host) != 1 {
        delete(conn.host)
        return false
    }

	return true
}

connection_make :: proc(client: ^Client, host: string, scheme := Scheme.From_Target, allocator := context.allocator) -> (conn: Connection) {
	connection_init(&conn, client, host, scheme, allocator)
	return
}

connection_destroy :: proc(conn: ^Connection) {
	log.warn("TODO", #procedure)
}

request_init :: proc(r: ^Request, conn: ^Connection, path: string, allocator := context.allocator) {
    r.allocator = allocator
    r.conn = conn

    r.path = http.url_parse(path).path
    r.path = strings.clone(r.path, allocator)

    http.headers_init(&r.headers, allocator)
    r.cookies.allocator  = allocator
    r.body.buf.allocator = allocator
    r.buf.buf.allocator  = allocator
}

request_make :: proc(conn: ^Connection, path: string, allocator := context.allocator) -> (r: Request) {
	request_init(&r, conn, path, allocator)
	return
}

// request_init_path :: proc(r: ^Request, conn: ^Connection, path: string)

// TODO: ssl stuff.
request_destroy :: proc(r: ^Request) {
	log.warn("TODO", #procedure)
 //    // Response.
 //    http.scanner_destroy(&r.res.scanner)
 //    http.headers_destroy(&r.res.headers)
 //    delete(&r.res.cookies)
	//
 //    // Request.
 //    http.headers_destroy(&r.headers)
 //    delete(r.cookies)
 //    strings.builder_destroy(&r.body)
 //    strings.builder_destroy(&r.buf)
	//
 //    // Connection.
	// delete(r.chost)
	// nbio.close(&r.io, r.socket) // NOTE: this is added to the event loop and doesn't close right away.
}

// TODO: request_destroy etc.

// TODO: helpful wrappers, like a `client.with_json()` and `client.get()` from v1.

// TODO: a client struct, optionally wrapping multiple requests.
// caching DNS resolutions...

// NOTE: openssl allocations are done using libc.
// TODO: can we set an allocator for openssl?

On_Connect :: #type proc(r: ^Connection, user_data: rawptr, err: net.Network_Error)

connect :: proc {
	connect_no_cb,
	connect_cb,
}

connect_no_cb :: #force_inline proc(c: ^Connection) { connect_cb(c, nil, proc(^Connection, rawptr, net.Network_Error) {}) }

// Resolves DNS if needed, then connects to the server, if there are requests queued it executes them.
// TODO: on success/failure, start doing all requests or call the request callback with an error.
connect_cb :: proc(c: ^Connection, user_data: rawptr, callback: On_Connect) {

    on_tcp_connect :: proc(c: ^Connection, user_data: rawptr, callback: On_Connect, socket: net.TCP_Socket, err: net.Network_Error) {
        if err != nil {
            log.errorf("TCP connect failed: %v", err)
			c.state = .Failed
            callback(c, user_data, err)
			connection_process(c)
            return
        }

        log.debug("TCP connection established")
        c.socket = socket

        if c.scheme != .HTTPS {
			c.state = .Connected
            callback(c, user_data, nil)
			connection_process(c)
            return
        }

        ssl.SSL_set_fd(c.ssl, i32(socket)) // TODO: can this error?

        ssl_connect :: proc(c: ^Connection, user_data: rawptr, callback: On_Connect, _: nbio.Poll_Event) {
            switch ret := ssl.SSL_connect(c.ssl); ret {
            case 1:
                log.debug("SSL connection established")
				c.state = .Connected
                callback(c, user_data, nil)
				connection_process(c)
            case 0:
                log.errorf("SSL connect error controlled shutdown: %v", ssl.error_get(c.ssl, ret))
				c.state = .Failed
                callback(c, user_data, net.Dial_Error.Refused)
				connection_process(c)
            case:
                assert(ret < 0)
                #partial switch err := ssl.error_get(c.ssl, ret); err {
                case .Want_Read:
                    log.debug("SSL connect want read")
                    nbio.poll(c.client.io, os.Handle(c.socket), .Read,  false, c, user_data, callback, ssl_connect)
                case .Want_Write:
                    log.debug("SSL connect want write")
                    nbio.poll(c.client.io, os.Handle(c.socket), .Write, false, c, user_data, callback, ssl_connect)
                case:
                    log.errorf("SSL connect fatal error: %v", err)
					c.state = .Failed
                    callback(c, user_data, net.Dial_Error.Refused)
					connection_process(c)
                }
            }
        }

        ssl_connect(c, user_data, callback, nil)
    }

	// Already connected/connecting.
	if c.state != .Pending {
		return
	}

	c.state = .Connecting

	// TODO: this is blocking.
	err: net.Network_Error
	if c.endpoint, err = parse_endpoint(string(c.host), c.scheme); err != nil do fmt.panicf("DNS error: %v", err)

    nbio.connect(c.client.io, c.endpoint, c, user_data, callback, on_tcp_connect)
}

On_Response :: #type proc(r: ^Request, user_data: rawptr, err: net.Network_Error)

request :: proc {
	request_cb,
	request_no_cb,
}

request_no_cb :: #force_inline proc(r: Request) { request_cb(r, nil, proc(^Request, rawptr, net.Network_Error) {}) }

request_cb :: proc(user_req: Request, user_data: rawptr, callback: On_Response) {
	r := new(Request)
	r^ = user_req

	r.on_response = callback
	r.user_data = user_data

	switch r.conn.state {
	case .Pending:
		r.conn.request = r
		connect_no_cb(r.conn)

	case .Connecting:
		if r.conn.request == nil {
			r.conn.request = r
		} else {
			tail: ^Request
			for tail = r.conn.request; tail != nil && tail.next != nil; tail = tail.next {}
			tail.next = r
		}
		connect_no_cb(r.conn)

	case .Failed:
		callback(r, user_data, net.Dial_Error.Refused)

	case .Connected:
		if r.conn.request == nil {
			r.conn.request = r
			connection_process(r.conn)
		} else {
			tail: ^Request
			for tail = r.conn.request; tail != nil && tail.next != nil; tail = tail.next {}
			tail.next = r
		}
	}
}

@(private="file")
connection_process :: proc(c: ^Connection) {
	fmt.println(c)
	switch c.state {
	case .Pending, .Connecting: panic("can't process requests if not connected")
	case .Failed:
		for req := c.request; req != nil; req = req.next {
			req.on_response(req, req.user_data, net.Dial_Error.Refused)
		}
	case .Connected:
		if c.request != nil {
			send(c.request)
		}
	}
}

@(private="file")
callback_and_process_next :: proc(r: ^Request, err: net.Network_Error) {

	// TODO: if error in connection, close connection and callback with an error.

	log.infof("request done: %v %v", r.res.status, err)

	// TODO: Fatal flaw, we are now trying to execute the next connection right away
	// but if the response had a body, it needs to be read first.
	// So we either need to read the body before calling this callback, or call the callback
	// and make it tell us it is done with the body, and then read it (if not read already) and
	// then send the next request.

	r.conn.request = r.next
	connection_process(r.conn)
	r.on_response(r, r.user_data, err)
}

@(private="file")
send :: proc(r: ^Request) {
    prepare_request(r)

	if r.conn.scheme != .HTTPS {
        // TODO: make nbio not pass the `sent` number in the send_all etc.

        // Send the request line and headers.
        nbio.send_all(r.conn.client.io, r.conn.socket, r.buf.buf[:], r, proc(r: ^Request, sent: int, err: net.Network_Error) {
            log.debugf("written request line and headers of %m to connection", sent)

            if len(r.body.buf) == 0 || err != nil {
				callback_and_process_next(r, err)
                return
            }

            // TODO: can we make sure the body hasn't changed between the send of the headers and this send, maybe assert the length?
            nbio.send_all(r.conn.client.io, r.conn.socket, r.body.buf[:], r, proc(r: ^Request, sent: int, err: net.Network_Error) {
                log.debugf("written body of %m to connection", sent)

				if err != nil {
					callback_and_process_next(r, err)
				}

				parse_response(r)
            })
        })
	}

    // TODO: test > 16kib writes.

    ssl_write_req :: proc(r: ^Request, _: nbio.Poll_Event) {
        bytes := len(r.buf.buf)
        switch ret := ssl.SSL_write(r.conn.ssl, raw_data(r.buf.buf), i32(bytes)); {
        case ret > 0:
            log.debugf("Successfully written request line and headers of %m to connection", ret)
            assert(int(ret) == bytes)
            ssl_write_body(r, nil)
        case:
            #partial switch err := ssl.error_get(r.conn.ssl, ret); err {
            case .Want_Read:
                log.debug("SSL write want read")
                nbio.poll(r.conn.client.io, os.Handle(r.conn.socket), .Read, false, r, ssl_write_req)
            case .Want_Write:
                log.debug("SSL write want write")
                nbio.poll(r.conn.client.io, os.Handle(r.conn.socket), .Write, false, r, ssl_write_req)
            case .Zero_Return:
                log.error("write failed, connection is closed")
				callback_and_process_next(r, net.TCP_Send_Error.Connection_Closed)
            case:
                log.errorf("write failed due to unknown reason: %v", err)
				callback_and_process_next(r, net.TCP_Send_Error.Aborted)
            }
        }
    }

    ssl_write_body :: proc(r: ^Request, _: nbio.Poll_Event) {
        bytes := len(r.body.buf)
        if bytes == 0 {
			parse_response(r)
            return
        }

        switch ret := ssl.SSL_write(r.conn.ssl, raw_data(r.body.buf), i32(bytes)); {
        case ret > 0:
            log.debugf("Successfully written body of %m to connection", ret)
            assert(int(ret) == bytes)
			parse_response(r)
        case:
            #partial switch err := ssl.error_get(r.conn.ssl, ret); err {
            case .Want_Read:
                log.debug("SSL write want read")
                nbio.poll(r.conn.client.io, os.Handle(r.conn.socket), .Read, false, r, ssl_write_body)
            case .Want_Write:
                log.debug("SSL write want write")
                nbio.poll(r.conn.client.io, os.Handle(r.conn.socket), .Write, false, r, ssl_write_body)
            case .Zero_Return:
                log.error("write failed, connection is closed")
                callback_and_process_next(r, net.TCP_Send_Error.Connection_Closed)
            case:
                log.errorf("write failed due to unknown reason: %v", err)
                callback_and_process_next(r, net.TCP_Send_Error.Aborted)
            }
        }
    }

    ssl_write_req(r, nil)
}

@(private="file")
prepare_response :: proc(r: ^Request) {
    scanner_recv :: proc(r: rawptr, buf: []byte, s: ^http.Scanner, callback: http.On_Scanner_Read) {
        r := (^Request)(r)

        if r.conn.scheme != .HTTPS {
            nbio.recv(r.conn.client.io, r.conn.socket, buf, s, callback, proc(s: ^http.Scanner, callback: http.On_Scanner_Read, n: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
                callback(s, n, err)
            })
            return
        }

        ssl_recv :: proc(r: ^Request, buf: []byte, callback: http.On_Scanner_Read, _: nbio.Poll_Event) {
            len := i32(len(buf)) // TODO: handle bigger than max recv at a time.
            log.debug("executing SSL read")
            switch ret := ssl.SSL_read(r.conn.ssl, raw_data(buf), len); {
            case ret > 0:
                log.debugf("Successfully received %m from the connection", ret)
                callback(&r.res.scanner, int(ret), nil)
            case:
                #partial switch err := ssl.error_get(r.conn.ssl, ret); err {
                case .Want_Read:
                    log.debug("SSL read want read")
                    nbio.poll(r.conn.client.io, os.Handle(r.conn.socket), .Read, false, r, buf, callback, ssl_recv)
                case .Want_Write:
                    log.debug("SSL read want write")
                    nbio.poll(r.conn.client.io, os.Handle(r.conn.socket), .Write, false, r, buf, callback, ssl_recv)
                case .Zero_Return:
                    log.error("read failed, connection is closed")
                    callback(&r.res.scanner, 0, net.TCP_Recv_Error.Connection_Closed)
                case:
                    log.errorf("read failed due to unknown reason: %v", err)
                    callback(&r.res.scanner, 0, net.TCP_Recv_Error.Aborted)
                }
            }
        }

        ssl_recv(r, buf, callback, nil)
    }

    http.headers_init(&r.res.headers, r.allocator)
    r.res.cookies.allocator = r.allocator

    http.scanner_init(&r.res.scanner, r, scanner_recv, r.allocator)
}

@(private="file")
parse_response :: proc(r: ^Request) {
    if r.res.scanner.recv == nil do prepare_response(r)

    map_err :: proc(err: bufio.Scanner_Error) -> net.Network_Error {
        return net.TCP_Recv_Error.Aborted // TODO;!
    }

    on_rline1 :: proc(r: rawptr, token: string, err: bufio.Scanner_Error) {
        r := (^Request)(r)
        if err != nil {
            log.errorf("error during read of first response line: %v", err)
			callback_and_process_next(r, map_err(err))
            return
        }

        // NOTE: this RFC advice for servers, but seems sensible here too.
        //
		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
        if len(token) == 0 {
            log.debug("first response line is empty, skipping in interest of robustness")
            http.scanner_scan(&r.res.scanner, r, on_rline2)
            return
        }

        on_rline2(r, token, nil)
    }

    on_rline2 :: proc(r: rawptr, token: string, err: bufio.Scanner_Error) {
        r := (^Request)(r)
        if err != nil {
            log.errorf("error during read of first response line: %v", err)
			callback_and_process_next(r, map_err(err))
            return
        }

        si := strings.index_byte(token, ' ')
        if si == -1 && si != len(token)-1 {
            log.errorf("invalid response line %q missing a space", token)
			callback_and_process_next(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        version, ok := http.version_parse(token[:si])
        if !ok || version.major != 1 {
            log.errorf("invalid HTTP version %q on response line %q", token[:si], token)
			callback_and_process_next(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        r.res.status, ok = http.status_from_string(token[si+1:])
        if !ok {
            log.errorf("invalid status %q on response line %q", token[si+1:], token)
			callback_and_process_next(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        log.debugf("got valid response line %q, parsing headers...", token)
        http.scanner_scan(&r.res.scanner, r, on_header_line)
    }

    on_header_line :: proc(r: rawptr, token: string, err: bufio.Scanner_Error) {
        r := (^Request)(r)
        if err != nil {
            log.errorf("error during read of header line: %v", err)
			callback_and_process_next(r, map_err(err))
            return
        }

        // First empty line means end of headers.
        if len(token) == 0 {
            on_headers_end(r)
            return
        }

        key, ok := http.header_parse(&r.res.headers, token, r.allocator)
        if !ok {
            log.errorf("invalid response header line %q", token)
			callback_and_process_next(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        if key == "set-cookie" {
			cookie_str := http.headers_get_unsafe(r.res.headers, "set-cookie")
			http.headers_delete_unsafe(&r.res.headers, "set-cookie")
			delete(key, r.allocator)

			cookie, cok := http.cookie_parse(cookie_str, r.allocator)
			if !cok {
                log.errorf("invalid cookie %q in header %q", cookie_str, token)
				callback_and_process_next(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
				return
			}

			append(&r.res.cookies, cookie)
        }

        log.debugf("parsed valid header %q", token)
        http.scanner_scan(&r.res.scanner, r, on_header_line)
    }

    on_headers_end :: proc(r: ^Request) {
        if !http.headers_validate(&r.res.headers) {
            log.errorf("invalid headers %v", r.res.headers._kv)
			callback_and_process_next(r, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        r.res.headers.readonly = true
		callback_and_process_next(r, nil)
    }

    http.scanner_scan(&r.res.scanner, r, on_rline1)
}

@(private="file")
prepare_request :: proc(r: ^Request) {
    strings.builder_reset(&r.buf)
    s := strings.to_stream(&r.buf)

    ws :: strings.write_string

    err := http.requestline_write(s, { method = r.method, target = r.path, version = {1, 1} })
    assert(err == nil) // Only really can be an allocator error.

	if !http.headers_has_unsafe(r.headers, "content-length") {
		buf_len := strings.builder_len(r.body)
		if buf_len == 0 {
		    ws(&r.buf, "content-length: 0\r\n")
		} else {
			ws(&r.buf, "content-length: ")

			// Make sure at least 20 bytes are there to write into, should be enough for the content length.
			strings.builder_grow(&r.buf, buf_len + 20)

			// Write the length into unwritten portion.
			unwritten := http._dynamic_unwritten(r.buf.buf)
			l := len(strconv.itoa(unwritten, buf_len))
			assert(l <= 20)
			http._dynamic_add_len(&r.buf.buf, l)

			ws(&r.buf, "\r\n")
		}
	}

	if !http.headers_has_unsafe(r.headers, "accept") {
		ws(&r.buf, "accept: */*\r\n")
	}

	if !http.headers_has_unsafe(r.headers, "user-agent") {
		ws(&r.buf, "user-agent: odin-http\r\n")
	}

	if !http.headers_has_unsafe(r.headers, "host") {
		ws(&r.buf, "host: ")
		ws(&r.buf, string(r.conn.host))
		ws(&r.buf, "\r\n")
	}

	for header, value in r.headers._kv {
		ws(&r.buf, header)
		ws(&r.buf, ": ")

		// Escape newlines in headers, if we don't, an attacker can find an endpoint
		// that returns a header with user input, and inject headers into the response.
		esc_value, was_allocation := strings.replace_all(value, "\n", "\\n", r.allocator)
		defer if was_allocation do delete(esc_value)

		ws(&r.buf, esc_value)
		ws(&r.buf, "\r\n")
	}

	if len(r.cookies) > 0 {
		ws(&r.buf, "cookie: ")

		for cookie, i in r.cookies {
			ws(&r.buf, cookie.name)
			ws(&r.buf, "=")
			ws(&r.buf, cookie.value)

			if i != len(r.cookies) - 1 {
				ws(&r.buf, "; ")
			}
		}

		ws(&r.buf, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	ws(&r.buf, "\r\n")
}

@(private="file")
parse_endpoint :: proc(host: string, scheme: Scheme) -> (endpoint: net.Endpoint, err: net.Network_Error) {
	host_or_endpoint := net.parse_hostname_or_endpoint(host) or_return

	switch t in host_or_endpoint {
	case net.Endpoint:
		endpoint = t
		return
	case net.Host:
		ep4, ep6 := net.resolve(t.hostname) or_return
		endpoint = ep4 if ep4.address != nil else ep6

		endpoint.port = t.port
		if endpoint.port == 0 {
			endpoint.port = scheme == .HTTPS ? 443 : 80
		}
		return
	case:
		unreachable()
	}
}
