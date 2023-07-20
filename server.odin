package http

import "core:net"
import "core:bufio"
import "core:log"
import "core:time"
import "core:thread"
import "core:mem"
import "core:mem/virtual"
import "core:runtime"
import "core:c/libc"
import "core:c"
import "core:os"
import "nbio"

Server_Opts :: struct {
	// Whether the server should accept every request that sends a "Expect: 100-continue" header automatically.
	// Defaults to true.
	auto_expect_continue: bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get: bool,
	// Limit the maximum number of bytes to read for the request line (first line of request containing the URI).
	// The HTTP spec does not specify any limits but in practice it is safer.
	// RFC 7230 3.1.1 says:
	// Various ad hoc limitations on request-line length are found in
	// practice.  It is RECOMMENDED that all HTTP senders and recipients
	// support, at a minimum, request-line lengths of 8000 octets.
	// defaults to 8000.
	limit_request_line:   int,
	// Limit the length of the headers.
	// The HTTP spec does not specify any limits but in practice it is safer.
	// defaults to 8000.
	limit_headers:        int,
}

Default_Server_Opts :: Server_Opts {
	auto_expect_continue = true,
	redirect_head_to_get = true,
	limit_request_line   = 8000,
	limit_headers        = 8000,
}

Server :: struct {
	opts:           Server_Opts,
	tcp_sock:       net.TCP_Socket,
	conn_allocator: mem.Allocator,
	conns:          map[net.TCP_Socket]^Connection,
	shutting_down:  bool,
	shut_down:      bool,
	handler:        Handler,
	io:             nbio.IO,
}

Default_Endpoint := net.Endpoint {
	address = net.IP4_Loopback,
	port    = 8080,
}

listen_and_serve :: proc(
	s: ^Server,
	h: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (
	err: net.Network_Error,
) {
	server_listen(s, endpoint, opts) or_return
	return server_serve(s, h)
}

server_listen :: proc(
	s: ^Server,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (
	err: net.Network_Error,
) {
	s.opts = opts
	s.tcp_sock, err = net.listen_tcp(endpoint)
	return
}

server_serve :: proc(s: ^Server, handler: Handler) -> net.Network_Error {
	s.handler = handler

	// Save allocator so we can free connections later.
	s.conn_allocator = context.allocator

	nbio.prepare_socket(s.tcp_sock)

	errno := nbio.init(&s.io)
	// TODO: error handling.
	assert(errno == os.ERROR_NONE)
	defer nbio.destroy(&s.io)

	log.debug("accepting connections")
	nbio.accept(&s.io, os.Socket(s.tcp_sock), s, on_accept)

	log.debug("starting event loop")
	for {
		if s.shutting_down {
			time.sleep(SHUTDOWN_INTERVAL)
			continue
		}

		if s.shut_down do break

		errno = nbio.tick(&s.io)
		// TODO: error handling.
		assert(errno == os.ERROR_NONE)
	}

	log.debug("event loop end")
	return nil
}

// The time between checks and closes of connections in a graceful shutdown.
@(private)
SHUTDOWN_INTERVAL :: time.Millisecond * 100

// Starts a graceful shutdown.
//
// Some error logs will be generated but all active connections are finished
// before closing them and all connections and threads are freed.
//
// 1. Stops 'server_start' from accepting new connections.
// 2. Close and free non-active connections.
// 3. Repeat 2 every SHUTDOWN_INTERVAL until no more connections are open.
// 4. Close the main socket.
// 5. Signal 'server_start' it can return.
server_shutdown :: proc(using s: ^Server) {
	shutting_down = true
	defer shutting_down = false
	defer shut_down = true
	defer delete(conns)

	for {
		for sock, conn in conns {
			#partial switch conn.state {
			case .Active:
				log.infof("shutdown: connection %i still active", sock)
			case .New, .Idle, .Pending:
				log.infof("shutdown: closing connection %i", sock)
				thread.run_with_poly_data(conn, connection_close, context)
			case .Closing:
				log.debugf("shutdown: connection %i is closing", sock)
			case .Closed:
				assert(false, "closed connections are not in this map")
			}
		}

		if len(conns) == 0 {
			break
		}

		time.sleep(SHUTDOWN_INTERVAL)
	}

	net.close(tcp_sock)

	nbio.destroy(&io)

	log.info("shutdown: done")
}

// If called after server_shutdown, will force the shutdown to go through open connections.
server_shutdown_force :: proc(s: ^Server) {
	log.info("forcing shutdown")

	for _, conn in s.conns {
		net.close(conn.socket)
	}

	time.sleep(SHUTDOWN_INTERVAL)

	os.exit(1)
}

@(private)
on_interrupt_server: ^Server
@(private)
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
// Can only be called once in the lifetime of the program because of a hacky interaction with libc.
server_shutdown_on_interrupt :: proc(using s: ^Server) {
	on_interrupt_server = s
	on_interrupt_context = context

	libc.signal(libc.SIGINT, proc "cdecl" (_: i32) {
		context = on_interrupt_context

		if on_interrupt_server.shutting_down {
			server_shutdown_force(on_interrupt_server)
			return
		}

		server_shutdown(on_interrupt_server)
	})
}

@(private)
server_on_connection_close :: proc(using s: ^Server, c: ^Connection) {
	free(c, conn_allocator)
	delete_key(&s.conns, c.socket)

	// TODO: clean up c.response inflight.
}


// Taken from Go's implementation,
// The maximum amount of bytes we will read (if handler did not)
// in order to get the connection ready for the next request.
@(private)
Max_Post_Handler_Discard_Bytes :: 256 << 10

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
@(private)
Conn_Close_Delay :: time.Millisecond * 500

Connection_State :: enum {
	Pending, // Pending a client to attach.
	New, // Got client, waiting to service first request.
	Active, // Servicing request.
	Idle, // Waiting for next request.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

Connection :: struct {
	server:    ^Server,
	socket:    net.TCP_Socket,
	client:    net.Endpoint,
	curr_req:  ^Request,
	state:     Connection_State,
	scanner:   Scanner,
	response:  Maybe(Response_Inflight),
}

Response_Inflight :: struct {
	buf:        []byte,
	sent:       int,
	will_close: bool,
}

// RFC 7230 6.6.
connection_close :: proc(c: ^Connection) {
	if c.state == .Closed {
		log.infof("connection %i already closed", c.socket)
		return
	}

	log.infof("closing connection: %i", c.socket)
	defer log.infof("closed connection: %i", c.socket)

	c.state = .Closing

	// TODO: non blocking.

	// Close read side of the connection, then wait a little bit, allowing the client
	// to process the closing and receive any remaining data.
	net.shutdown(c.socket, net.Shutdown_Manner.Send)

	// This will block the whole thread, but we have one thread per connection anyway,
	// so should not matter as long as this is done after sending everything.
	time.sleep(Conn_Close_Delay)
	net.close(c.socket)

	c.state = .Closed

	server_on_connection_close(c.server, c)
}

@(private)
on_accept :: proc(
	server: rawptr,
	sock: os.Socket,
	addr: os.SOCKADDR_STORAGE_LH,
	addr_len: c.int,
	err: os.Errno,
) {
	server := cast(^Server)server
	addr := addr

	// Accept next connection.
	// TODO: is this how it should be done (performance wise)?
	nbio.accept(&server.io, os.Socket(server.tcp_sock), server, on_accept)

	ep := sockaddr_to_endpoint(&addr)
	client := net.TCP_Socket(sock)

	c := new(Connection, server.conn_allocator)
	c.state = .New
	c.server = server
	c.client = ep
	c.socket = client

	server.conns[c.socket] = c

	log.infof("new connection with %v, got %d conns", ep, len(server.conns))
	conn_handle_reqs(c)
}

@(private)
conn_handle_reqs :: proc(c: ^Connection) {
	scanner_init(&c.scanner, c, c.server.conn_allocator)

	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		panic("could not create memory arena")
	}
	allocator := virtual.arena_allocator(&arena)
	context.temp_allocator = allocator

	log.debugf("started handling requests for connection with %s", net.endpoint_to_string(c.client, context.temp_allocator))
	conn_handle_req(c)
}

// Loop/request cycle state.
@(private)
Loop :: struct {
	conn: ^Connection,
	req:  Request,
	res:  Response,
}

@(private)
conn_handle_req :: proc(c: ^Connection) {
	on_rline1 :: proc(loop: rawptr, token: []byte, err: bufio.Scanner_Error) {
		context.allocator = context.temp_allocator
		loop := cast(^Loop)loop
		using loop

		conn.state = .Active

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(conn, close = true)
			return
		}

		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
		if len(token) == 0 {
			log.debug("first request line empty, skipping in interest of robustness")
			scanner_scan(&conn.scanner, loop, on_rline2)
			return
		}

		on_rline2(loop, token, err)
	}

	on_rline2 :: proc(loop: rawptr, token: []byte, err: bufio.Scanner_Error) {
		context.allocator = context.temp_allocator
		loop := cast(^Loop)loop
		using loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(conn, close = true)
			return
		}

		rline, err := requestline_parse(string(token))
		switch err {
		case .Method_Not_Implemented:
			log.infof("request-line %q invalid method", string(token))
			res.headers["connection"] = "close"
			res.status = .Not_Implemented
			respond(&res)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			log.warnf("request-line %q invalid: %s", string(token), err)
			clean_request_loop(conn, close = true)
			return
		case .None:
			req.line = rline
		}

		// Might need to support more versions later.
		if rline.version.major != 1 || rline.version.minor < 1 {
			log.infof("request http version not supported %v", rline.version)
			res.headers["connection"] = "close"
			res.status = .HTTP_Version_Not_Supported
			respond(&res)
			return
		}

		req.url = url_parse(rline.target)

		conn.scanner.max_token_size = conn.server.opts.limit_headers
		scanner_scan(&conn.scanner, loop, on_header_line)
	}

	on_header_line :: proc(loop: rawptr, token: []byte, err: bufio.Scanner_Error) {
		context.allocator = context.temp_allocator
		loop := cast(^Loop)loop
		using loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(conn, close = true)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(loop)
			return
		}

		if _, ok := header_parse(&req.headers, string(token)); !ok {
			log.warnf("header-line %s is invalid", string(token))
			res.headers["connection"] = "close"
			res.status = .Bad_Request
			respond(&res)
			return
		}

		conn.scanner.max_token_size -= len(token)
		if conn.scanner.max_token_size <= 0 {
			log.warn("request headers too large")
			res.headers["connection"] = "close"
			res.status = .Request_Header_Fields_Too_Large
			respond(&res)
			return
		}

		scanner_scan(&conn.scanner, loop, on_header_line)
	}

	on_headers_end :: proc(using loop: ^Loop) {
		if !server_headers_validate(&req.headers) {
			log.warn("request headers are invalid")
			res.headers["connection"] = "close"
			res.status = .Bad_Request
			respond(&res)
			return
		}

		conn.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := req.headers["expect"];
		   ok && expect == "100-continue" && conn.server.opts.auto_expect_continue {

			res.status = .Continue

			respond(&res)
			return
		}

		req._scanner = conn.scanner

		rline := req.line.(Requestline)
		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target == "*" {
			res.status = .Ok
			respond(&res)
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			is_head := rline.method == .Head
			if is_head && conn.server.opts.redirect_head_to_get {
				req.is_head = true
				rline.method = .Get
			}

			conn.server.handler.handle(&conn.server.handler, &req, &res)
		}
	}

	loop := new(Loop, context.temp_allocator)
	loop.conn = c
	loop.res._conn = c

	request_init(&loop.req)
	response_init(&loop.res)

	c.curr_req = &loop.req

	log.debugf("waiting for next request on %s", net.endpoint_to_string(c.client, context.temp_allocator))

	c.scanner.max_token_size = c.server.opts.limit_request_line
	scanner_scan(&c.scanner, loop, on_rline1)
}

@(private)
sockaddr_to_endpoint :: proc(native_addr: ^os.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
	addr := native_addr.family when ODIN_OS == .Darwin else native_addr.ss_family
	switch addr {
	case os.ADDRESS_FAMILY(os.AF_INET):
		addr := cast(^os.sockaddr_in)native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte)addr.sin_addr),
			port    = port,
		}
	case os.ADDRESS_FAMILY(os.AF_INET6):
		addr := cast(^os.sockaddr_in6)native_addr
		port := int(addr.sin6_port)
		ep = net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be)addr.sin6_addr),
			port    = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
}
