// package client provides a HTTP/1.1 client.
package client

import "core:bufio"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"

import http ".."
import nbio "../nbio/poly"
import ssl  "../openssl"

// TODO: max response line/header/body sizes.

Request :: struct {
	// scanner: http.Scanner,
    allocator: mem.Allocator,
    io:        ^nbio.IO,

    target:    http.URL,
    endpoint:  net.Endpoint,
    chost:     cstring,

    ctx:       ^ssl.SSL_CTX,
    ssl:       ^ssl.SSL,

    socket:    net.TCP_Socket,

    method:    http.Method,
    headers:   http.Headers,
    cookies:   [dynamic]http.Cookie,
    body:      strings.Builder,

    buf:       strings.Builder,

    res:       Response,

    on_response:           On_Response,
    on_response_user_data: rawptr,
}

// TODO: request_destroy etc.

// TODO: helpful wrappers, like a `client.with_json()` and `client.get()` from v1.

// TODO: a client struct, optionally wrapping multiple requests.
// caching DNS resolutions...

// TODO: a structure like below, where you have a connection struct holding everything for
// the actual connection, so everything needed up to connection to the host server.
// Now, for http 1, that doesn't have much value, because you need to be sequential over a connection.
//
// Request :: struct {
//     using conn: ^Connection,
//
//     method:    http.Method,
//     headers:   http.Headers,
//     cookies:   [dynamic]http.Cookie,
//     body:      strings.Builder,
//
//     buf:       strings.Builder,
//
// }

Response :: struct {
    scanner: http.Scanner,

    cb:        On_Response,
    user_data: rawptr,

    status:  http.Status,
    headers: http.Headers,
    cookies: [dynamic]http.Cookie,
}

// NOTE: openssl allocations are done using libc.
// TODO: can we set an allocator for openssl?
request_init :: proc(io: ^nbio.IO, r: ^Request, target: string, allocator := context.allocator) -> net.Network_Error {
    r.allocator = allocator
    r.target, r.endpoint = parse_endpoint(target) or_return // TODO: THIS IS BLOCKING.
    r.io = io

    http.headers_init(&r.headers, allocator)

    r.cookies.allocator  = allocator
    r.body.buf.allocator = allocator
    r.buf.buf.allocator  = allocator

    if r.target.scheme != "https" do return nil

    // TODO: error handling here.
    r.ctx = ssl.SSL_CTX_new(ssl.TLS_client_method())
    r.ssl = ssl.SSL_new(r.ctx)

	// For servers using SNI for SSL certs (like cloudflare), this needs to be set.
    r.chost = strings.clone_to_cstring(r.target.host, allocator)
    ssl.SSL_set_tlsext_host_name(r.ssl, r.chost)
    return nil
}

On_Connect :: #type proc(r: ^Request, user_data: rawptr, err: net.Network_Error)

connect :: proc(r: ^Request, user_data: rawptr, callback: On_Connect) {

    on_tcp_connect :: proc(r: ^Request, user_data: rawptr, callback: On_Connect, socket: net.TCP_Socket, err: net.Network_Error) {
        if err != nil {
            log.errorf("TCP connect failed: %v", err)
            callback(r, user_data, err)
            return
        }

        log.debug("TCP connection established")
        r.socket = socket

        if r.target.scheme != "https" {
            callback(r, user_data, nil)
            return
        }

        ssl.SSL_set_fd(r.ssl, i32(socket)) // TODO: can this error?

        ssl_connect :: proc(r: ^Request, user_data: rawptr, callback: On_Connect, _: nbio.Poll_Event) {
            switch ret := ssl.SSL_connect(r.ssl); ret {
            case 1:
                log.debug("SSL connection established")
                callback(r, user_data, nil)
            case 0:
                log.errorf("SSL connect error controlled shutdown: %v", ssl.error_get(r.ssl, ret))
                callback(r, user_data, net.Dial_Error.Refused)
            case:
                assert(ret < 0)
                #partial switch err := ssl.error_get(r.ssl, ret); err {
                case .Want_Read:
                    log.debug("SSL connect want read")
                    nbio.poll(r.io, os.Handle(r.socket), .Read,  false, r, user_data, callback, ssl_connect)
                case .Want_Write:
                    log.debug("SSL connect want write")
                    nbio.poll(r.io, os.Handle(r.socket), .Write, false, r, user_data, callback, ssl_connect)
                case:
                    log.errorf("SSL connect fatal error: %v", err)
                    callback(r, user_data, net.Dial_Error.Refused)
                }
            }
        }

        ssl_connect(r, user_data, callback, nil)
    }

    nbio.connect(r.io, r.endpoint, r, user_data, callback, on_tcp_connect)
}

On_Sent :: #type proc(r: ^Request, user_data: rawptr, err: net.Network_Error)

send :: proc(r: ^Request, user_data: rawptr, callback: On_Sent) {
    if len(r.buf.buf) == 0 do prepare_request(r)

    if r.target.scheme != "https" {
        nbio.send_all(r.io, r.socket, r.buf.buf[:], r, user_data, callback, proc(r: ^Request, user_data: rawptr, callback: On_Sent, sent: int, err: net.Network_Error) {
            log.debugf("written request of %m to connection", sent)
            callback(r, user_data, err)
        })
        return
    }

    // TODO: test > 16kib writes.

    ssl_write :: proc(r: ^Request, user_data: rawptr, callback: On_Sent, _: nbio.Poll_Event) {
        len := i32(strings.builder_len(r.buf)) // TODO: handle bigger than max send at a time.
        switch ret := ssl.SSL_write(r.ssl, raw_data(r.buf.buf), i32(len)); {
        case ret > 0:
            log.debugf("Successfully written request of %m to connection", ret)
            assert(ret == len)
            callback(r, user_data, nil)
        case:
            #partial switch err := ssl.error_get(r.ssl, ret); err {
            case .Want_Read:
                log.debug("SSL write want read")
                nbio.poll(r.io, os.Handle(r.socket), .Read, false, r, user_data, callback, ssl_write)
            case .Want_Write:
                log.debug("SSL write want write")
                nbio.poll(r.io, os.Handle(r.socket), .Write, false, r, user_data, callback, ssl_write)
            case .Zero_Return:
                log.error("write failed, connection is closed")
                callback(r, user_data, net.TCP_Send_Error.Connection_Closed)
            case:
                log.errorf("write failed due to unknown reason: %v", err)
                callback(r, user_data, net.TCP_Send_Error.Aborted)
            }
        }
    }

    log.debugf("sending body: %q", strings.to_string(r.buf))

    ssl_write(r, user_data, callback, nil)
}

prepare_response :: proc(r: ^Request) {
    scanner_recv :: proc(r: rawptr, buf: []byte, s: ^http.Scanner, callback: http.On_Scanner_Read) {
        r := (^Request)(r)

        if r.target.scheme != "https" {
            nbio.recv(r.io, r.socket, buf, s, callback, proc(s: ^http.Scanner, callback: http.On_Scanner_Read, n: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
                callback(s, n, err)
            })
            return
        }

        ssl_recv :: proc(r: ^Request, buf: []byte, callback: http.On_Scanner_Read, _: nbio.Poll_Event) {
            len := i32(len(buf)) // TODO: handle bigger than max recv at a time.
            log.debug("executing SSL read")
            switch ret := ssl.SSL_read(r.ssl, raw_data(buf), len); {
            case ret > 0:
                log.debugf("Successfully received %m from the connection", ret)
                callback(&r.res.scanner, int(ret), nil)
            case:
                #partial switch err := ssl.error_get(r.ssl, ret); err {
                case .Want_Read:
                    log.debug("SSL read want read")
                    nbio.poll(r.io, os.Handle(r.socket), .Read, false, r, buf, callback, ssl_recv)
                case .Want_Write:
                    log.debug("SSL read want write")
                    nbio.poll(r.io, os.Handle(r.socket), .Write, false, r, buf, callback, ssl_recv)
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

On_Response :: #type proc(r: ^Response, user_data: rawptr, err: net.Network_Error)

parse_response :: proc(r: ^Request, user_data: rawptr, callback: On_Response) {
    if r.res.scanner.recv == nil do prepare_response(r)

    map_err :: proc(err: bufio.Scanner_Error) -> net.Network_Error {
        return net.TCP_Recv_Error.Aborted // TODO;!
    }

    on_rline1 :: proc(r: rawptr, token: string, err: bufio.Scanner_Error) {
        r := (^Request)(r)
        if err != nil {
            log.errorf("error during read of first response line: %v", err)
            r.res.cb(&r.res, r.res.user_data, map_err(err))
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
            r.res.cb(&r.res, r.res.user_data, map_err(err))
            return
        }

        si := strings.index_byte(token, ' ')
        if si == -1 && si != len(token)-1 {
            log.errorf("invalid response line %q missing a space", token)
            r.res.cb(&r.res, r.res.user_data, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        version, ok := http.version_parse(token[:si])
        if !ok || version.major != 1 {
            log.errorf("invalid HTTP version %q on response line %q", token[:si], token)
            r.res.cb(&r.res, r.res.user_data, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        r.res.status, ok = http.status_from_string(token[si+1:])
        if !ok {
            log.errorf("invalid status %q on response line %q", token[si+1:], token)
            r.res.cb(&r.res, r.res.user_data, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        log.debugf("got valid response line %q, parsing headers...", token)
        http.scanner_scan(&r.res.scanner, r, on_header_line)
    }

    on_header_line :: proc(r: rawptr, token: string, err: bufio.Scanner_Error) {
        r := (^Request)(r)
        if err != nil {
            log.errorf("error during read of header line: %v", err)
            r.res.cb(&r.res, r.res.user_data, map_err(err))
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
            r.res.cb(&r.res, r.res.user_data, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        if key == "set-cookie" {
			cookie_str := http.headers_get_unsafe(r.res.headers, "set-cookie")
			http.headers_delete_unsafe(&r.res.headers, "set-cookie")
			delete(key, r.allocator)

			cookie, cok := http.cookie_parse(cookie_str, r.allocator)
			if !cok {
                log.errorf("invalid cookie %q in header %q", cookie_str, token)
                r.res.cb(&r.res, r.res.user_data, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
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
            r.res.cb(&r.res, r.res.user_data, net.TCP_Recv_Error.Aborted) // TODO: a proper error.
            return
        }

        r.res.headers.readonly = true
        r.res.cb(&r.res, r.res.user_data, nil)
    }

    // NOTE: I feel iffie about this
    r.res.cb        = callback
    r.res.user_data = user_data

    http.scanner_scan(&r.res.scanner, r, on_rline1)
}

prepare_request :: proc(r: ^Request) {
    strings.builder_reset(&r.buf)
    s := strings.to_stream(&r.buf)

    ws :: strings.write_string

    err := http.requestline_write(s, { method = r.method, target = r.target, version = {1, 1} })
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
		ws(&r.buf, r.target.host)
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

    ws(&r.buf, strings.to_string(r.body))
}

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
