package http

import "core:bufio"
import "core:bytes"
import "core:c/libc"
import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:runtime"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import "nbio"

Server_Opts :: struct {
	// Whether the server should accept every request that sends a "Expect: 100-continue" header automatically.
	// Defaults to true.
	auto_expect_continue:    bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get:    bool,
	// Limit the maximum number of bytes to read for the request line (first line of request containing the URI).
	// The HTTP spec does not specify any limits but in practice it is safer.
	// RFC 7230 3.1.1 says:
	// Various ad hoc limitations on request-line length are found in
	// practice.  It is RECOMMENDED that all HTTP senders and recipients
	// support, at a minimum, request-line lengths of 8000 octets.
	// defaults to 8000.
	limit_request_line:      int,
	// Limit the length of the headers.
	// The HTTP spec does not specify any limits but in practice it is safer.
	// defaults to 8000.
	limit_headers:           int,
	// The thread count to use, defaults to your core count - 1.
	thread_count:            int,
	// The initial size of the temp_allocator for each connection, defaults to 256KiB and doubles
	// each time it needs to grow.
	// NOTE: this value is assigned globally, running multiple servers with a different value will
	// not work.
	initial_temp_block_cap:  uint,
	// The amount of free blocks each thread is allowed to hold on to before deallocating excess.
	// Defaults to 64.
	max_free_blocks_queued:  uint,
}

Default_Server_Opts := Server_Opts {
	auto_expect_continue    = true,
	redirect_head_to_get    = true,
	limit_request_line      = 8000,
	limit_headers           = 8000,
	initial_temp_block_cap  = 256 * mem.Kilobyte,
	max_free_blocks_queued  = 64,
}

@(init, private)
server_opts_init :: proc() {
	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		Default_Server_Opts.thread_count = os.processor_core_count()
	} else {
		Default_Server_Opts.thread_count = 1
	}
}

Server_State :: enum {
	Uninitialized,
	Idle,
	Listening,
	Serving,
	Running,
	Closing,
	Cleaning,
	Closed,
}

Server :: struct {
	opts:           Server_Opts,
	tcp_sock:       net.TCP_Socket,
	conn_allocator: mem.Allocator,
	handler:        Handler,
	main_thread:    int,

	threads:        []^thread.Thread,
	// Once the server starts closing/shutdown this is set to true, all threads will check it
	// and start their thread local shutdown procedure.
	closing:        bool,
	// Threads will decrement the wait group when they have fully closed/shutdown.
	// The main thread waits on this to clean up global data and return.
	threads_closed: sync.Wait_Group,

	// Updated every second with an updated date, this speeds up the server considerably
	// because it would otherwise need to call time.now() and format the date on each response.
	date:           Server_Date,
}

Server_Thread :: struct {
	conns: map[net.TCP_Socket]^Connection,
	state: Server_State,
	io:    nbio.IO,

	free_temp_blocks:       map[int]queue.Queue(^Block),
	free_temp_blocks_count: int,
}

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_has_td :: #force_inline proc(loc := #caller_location) {
	assert(td.state != .Uninitialized, "The thread you are calling from is not a server/handler thread", loc)
}

@(thread_local)
td: Server_Thread

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
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
	s.handler = h
	s.opts = opts
	s.conn_allocator = context.allocator
	s.main_thread = sync.current_thread_id()
	initial_block_cap = int(s.opts.initial_temp_block_cap)
	max_free_blocks_queued = int(s.opts.max_free_blocks_queued)

	errno := nbio.init(&td.io)
	// TODO: error handling.
	assert(errno == os.ERROR_NONE)

	s.tcp_sock, err = nbio.open_and_listen_tcp(&td.io, endpoint)
	if err != nil {
		server_shutdown(s)
		return
	}

	thread_count := max(0, s.opts.thread_count - 1)
	sync.wait_group_add(&s.threads_closed, thread_count)
	s.threads = make([]^thread.Thread, thread_count, s.conn_allocator)
	for i in 0 ..< thread_count {
		s.threads[i] = thread.create_and_start_with_poly_data(s, _server_thread_init, context)
	}

	// Start keeping track of and caching the date for the required date header.
	server_date_start(s)

	sync.wait_group_add(&s.threads_closed, 1)
	_server_thread_init(s)

	sync.wait(&s.threads_closed)

	log.debug("threads are shut down, shutting down main thread")

	net.close(s.tcp_sock)
	for t in s.threads do free(t, s.conn_allocator)
	delete(s.threads)

	return nil
}

_server_thread_init :: proc(s: ^Server) {
	td.conns            = make(map[net.TCP_Socket]^Connection)
	td.free_temp_blocks = make(map[int]queue.Queue(^Block))

	if sync.current_thread_id() != s.main_thread {
		errno := nbio.init(&td.io)
		// TODO: error handling.
		assert(errno == os.ERROR_NONE)
	}

	log.debug("accepting connections")

	nbio.accept(&td.io, s.tcp_sock, s, on_accept)

	log.debug("starting event loop")
	td.state = .Serving
	for {
		if s.closing do _server_thread_shutdown(s)
		if td.state == .Closed do break
		if td.state == .Cleaning do continue

		errno := nbio.tick(&td.io)
		if errno != os.ERROR_NONE {
			// TODO: check how this behaves on Windows.
			when ODIN_OS != .Windows do if errno == os.EINTR {
				server_shutdown(s)
				continue
			}

			log.errorf("non-blocking io tick error: %v", errno)
			break
		}
	}

	log.debug("event loop end")

	sync.wait_group_done(&s.threads_closed)
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
server_shutdown :: proc(s: ^Server) {
	s.closing = true
}

_server_thread_shutdown :: proc(s: ^Server, loc := #caller_location) {
	assert_has_td(loc)

	td.state = .Closing
	defer delete(td.conns)
	defer {
		blocks: int
		for _, &bucket in td.free_temp_blocks {
			for block in queue.pop_front_safe(&bucket) {
				blocks += 1
				free(block)
			}
			queue.destroy(&bucket)
		}
		delete(td.free_temp_blocks)
		log.infof("had %i temp blocks to spare", blocks)
	}

	for i := 0; ; i += 1 {
		for sock, conn in td.conns {
			#partial switch conn.state {
			case .Active:
				log.infof("shutdown: connection %i still active", sock)
			case .New, .Idle, .Pending:
				log.infof("shutdown: closing connection %i", sock)
				connection_close(conn)
			case .Closing:
				// Only logging this every 10_000 calls to avoid spam.
				if i % 10_000 == 0 do log.debugf("shutdown: connection %i is closing", sock)
			case .Closed:
				log.warn("closed connection in connections map, maybe a race or logic error")
			}
		}

		if len(td.conns) == 0 {
			break
		}

		err := nbio.tick(&td.io)
		fmt.assertf(err == os.ERROR_NONE, "IO tick error during shutdown: %v")
	}

	td.state = .Cleaning
	nbio.destroy(&td.io)
	td.state = .Closed

	log.info("shutdown: done")
}

@(private)
on_interrupt_server: ^Server
@(private)
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
// Can only be called once in the lifetime of the program because of a hacky interaction with libc.
server_shutdown_on_interrupt :: proc(s: ^Server) {
	on_interrupt_server = s
	on_interrupt_context = context

	libc.signal(
		libc.SIGINT,
		proc "cdecl" (_: i32) {
			context = on_interrupt_context

			// Force close on second signal.
			if td.state == .Closing {
				os.exit(1)
			}

			server_shutdown(on_interrupt_server)
		},
	)
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
	Will_Close, // Closing after the current response is sent.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

@(private)
connection_set_state :: proc(c: ^Connection, s: Connection_State) -> bool {
	if s < .Closing && c.state >= .Closing {
		return false
	}

	if s == .Closing && c.state == .Closed {
		return false
	}

	c.state = s
	return true
}

Connection :: struct {
	server:         ^Server,
	socket:         net.TCP_Socket,
	state:          Connection_State,
	scanner:        Scanner,
	temp_allocator: Allocator,
	loop:           Loop,
}

// Loop/request cycle state.
@(private)
Loop :: struct {
	conn: ^Connection,
	req:  Request,
	res:  Response,
}

@(private)
connection_close :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)

	if c.state >= .Closing {
		log.infof("connection %i already closing/closed", c.socket)
		return
	}

	log.debugf("closing connection: %i", c.socket)

	c.state = .Closing

	// RFC 7230 6.6.

	// Close read side of the connection, then wait a little bit, allowing the client
	// to process the closing and receive any remaining data.
	net.shutdown(c.socket, net.Shutdown_Manner.Send)

	scanner_destroy(&c.scanner)

	nbio.timeout(&td.io, Conn_Close_Delay, c, proc(c: rawptr, _: Maybe(time.Time)) {
		c := cast(^Connection)c
		nbio.close(&td.io, c.socket, c, proc(c: rawptr, ok: bool) {
			c := cast(^Connection)c

			log.debugf("closed connection: %i", c.socket)

			c.state = .Closed

			allocator_destroy(&c.temp_allocator)
			delete_key(&td.conns, c.socket)
			free(c, c.server.conn_allocator)
		})
	})
}

@(private)
on_accept :: proc(server: rawptr, sock: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
	server := cast(^Server)server

	if err != nil {
		#partial switch e in err {
		case net.Accept_Error:
			#partial switch e {
			case .No_Socket_Descriptors_Available_For_Client_Socket:
				log.error("Connection limit reached, trying again in a bit")
				nbio.timeout(&td.io, time.Second, server, proc(server: rawptr, _: Maybe(time.Time)) {
					server := cast(^Server)server
					nbio.accept(&td.io, server.tcp_sock, server, on_accept)
				})
				return
			}
		}

		fmt.panicf("accept error: %v", err)
	}

	// Accept next connection.
	nbio.accept(&td.io, server.tcp_sock, server, on_accept)

	c := new(Connection, server.conn_allocator)
	c.state = .New
	c.server = server
	c.socket = sock

	td.conns[c.socket] = c

	log.debugf("new connection with thread, got %d conns", len(td.conns))
	conn_handle_reqs(c)
}

@(private)
conn_handle_reqs :: proc(c: ^Connection) {
	scanner_init(&c.scanner, c, c.server.conn_allocator)
	allocator_init(&c.temp_allocator, c.server.conn_allocator)
	context.temp_allocator = allocator(&c.temp_allocator)
	conn_handle_req(c, context.temp_allocator)
}

@(private)
conn_handle_req :: proc(c: ^Connection, allocator := context.temp_allocator) {
	on_rline1 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if !connection_set_state(l.conn, .Active) do return

		if err != nil {
			if err == .EOF {
				log.debugf("client disconnected (EOF)")
			} else {
				log.warnf("request scanner error: %v", err)
			}

			clean_request_loop(l.conn, close = true)
			return
		}

		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
		if len(token) == 0 {
			log.debug("first request line empty, skipping in interest of robustness")
			scanner_scan(&l.conn.scanner, loop, on_rline2)
			return
		}

		on_rline2(loop, token, err)
	}

	on_rline2 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		rline, err := requestline_parse(string(token))
		switch err {
		case .Method_Not_Implemented:
			log.infof("request-line %q invalid method", string(token))
			headers_set_close(&l.res.headers)
			l.res.status = .Not_Implemented
			respond(&l.res)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			log.warnf("request-line %q invalid: %s", string(token), err)
			clean_request_loop(l.conn, close = true)
			return
		case .None:
			l.req.line = rline
		}

		// Might need to support more versions later.
		if rline.version.major != 1 || rline.version.minor < 1 {
			log.infof("request http version not supported %v", rline.version)
			headers_set_close(&l.res.headers)
			l.res.status = .HTTP_Version_Not_Supported
			respond(&l.res)
			return
		}

		// TODO: don't parse the URL here, user or middleware can always do it if needed.
		l.req.url = url_parse(rline.target.(string), context.temp_allocator)

		l.conn.scanner.max_token_size = l.conn.server.opts.limit_headers
		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_header_line :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(l)
			return
		}

		if _, ok := header_parse(&l.req.headers, string(token)); !ok {
			log.warnf("header-line %s is invalid", string(token))
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.conn.scanner.max_token_size -= len(token)
		if l.conn.scanner.max_token_size <= 0 {
			log.warn("request headers too large")
			headers_set_close(&l.res.headers)
			l.res.status = .Request_Header_Fields_Too_Large
			respond(&l.res)
			return
		}

		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_headers_end :: proc(l: ^Loop) {
		if !headers_validate_for_server(&l.req.headers) {
			log.warn("request headers are invalid")
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.req.headers.readonly = true

		l.conn.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := headers_get_unsafe(l.req.headers, "expect");
		   ok && expect == "100-continue" && l.conn.server.opts.auto_expect_continue {

			l.res.status = .Continue

			respond(&l.res)
			return
		}

		l.req._scanner = &l.conn.scanner

		rline := l.req.line.(Requestline)
		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target.(string) == "*" {
			l.res.status = .OK
			respond(&l.res)
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			is_head := rline.method == .Head
			if is_head && l.conn.server.opts.redirect_head_to_get {
				l.req.is_head = true
				rline.method = .Get
			}

			l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.res)
		}
	}

	c.loop.conn = c
	c.loop.res._conn = c
	request_init(&c.loop.req, allocator)
	response_init(&c.loop.res, allocator)

	c.scanner.max_token_size = c.server.opts.limit_request_line
	scanner_scan(&c.scanner, &c.loop, on_rline1)
}

// A buffer that will contain the date header for the current second.
@(private)
Server_Date :: struct {
	buf_backing: [DATE_LENGTH]byte,
	buf:         bytes.Buffer,
}

@(private)
server_date_start :: proc(s: ^Server) {
	s.date.buf.buf = slice.into_dynamic(s.date.buf_backing[:])
	server_date_update(s, time.now())
}

// Updates the time and schedules itself for after a second.
@(private)
server_date_update :: proc(s: rawptr, now: Maybe(time.Time)) {
	s := cast(^Server)s
	nbio.timeout(&td.io, time.Second, s, server_date_update)

	bytes.buffer_reset(&s.date.buf)
	date_write(bytes.buffer_to_stream(&s.date.buf), now.? or_else time.now())
}

@(private)
server_date :: proc(s: ^Server) -> string {
	return string(s.date.buf_backing[:])
}
