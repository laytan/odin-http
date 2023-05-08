package http

import "core:net"
import "core:io"
import "core:bufio"
import "core:log"
import "core:time"
import "core:thread"
import "core:sync"
import "core:mem"
import "core:runtime"
import "core:c/libc"

Server_Opts :: struct {
	// Whether the server should accept every request that sends a "Expect: 100-continue" header automatically.
	// Defaults to true.
	auto_expect_continue: bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get: bool,
}

Default_Server_Opts :: Server_Opts {
	auto_expect_continue = true,
	redirect_head_to_get = true,
}

Server :: struct {
	opts:           Server_Opts,
    tcp_sock:       net.TCP_Socket,

	conn_allocator: mem.Allocator,
	conns:          map[net.TCP_Socket]^Connection,

	shutting_down:  bool,
}

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 80,
}

server_listen :: proc(s: ^Server, endpoint: net.Endpoint = Default_Endpoint, opts: Server_Opts = Default_Server_Opts) -> (err: net.Network_Error) {
	s.opts = opts
	s.tcp_sock, err = net.listen_tcp(endpoint)
    return
}

server_serve :: proc(using s: ^Server, handler: proc(^Request, ^Response)) -> net.Network_Error {
	// Save allocator so we can free connections later.
	conn_allocator = context.allocator

	for {
		// Don't accept more connections when we are shutting down,
		// but we don't want to return yet, this way users can wait for this
		// proc to return as well as the shutdown proc.
		if shutting_down {
			time.sleep(SHUTDOWN_INTERVAL)
			continue
		}

		c := new(Connection, conn_allocator)
		c.state     = .Pending
		c.server    = s
		c.handler   = handler
		c.socket_mu = sync.Mutex{}
		sync.mutex_lock(&c.socket_mu)

		// Each connection has its own thread. This has to be the case because
		// sockets are blocking in the 'net' package of Odin.
		//
		// We use the mutex so we can start a thread before accepting the connection,
		// this way, the first request of a connection does not have to wait for
		// the thread to spin up.
        c.thread = thread.create_and_start_with_poly_data(c, proc(c: ^Connection) {
			// Will block until main thread unlocks the mutex, indicating a connection is ready.
			sync.mutex_lock(&c.socket_mu)

			c.state = .New
			if err := conn_handle_reqs(c); err != nil {
				log.errorf("connection error: %s", err)
			}
		}, context)

        client, _, err := net.accept_tcp(s.tcp_sock)
		if err != nil {
			free(c.thread)
			free(c)
			return err
		}

		c.socket = client

		conns[client] = c

		sync.mutex_unlock(&c.socket_mu)
	}
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
	defer shutting_down = false // causes 'server_start' to return.
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
	log.info("shutdown: done")
}

@(private)
on_interrupt_server: ^Server
@(private)
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
// Can only be called once in the lifetime of the program because of a hacky interaction with libc.
server_shutdown_on_interrupt :: proc(using s: ^Server) {
	on_interrupt_server  = s
	on_interrupt_context = context

	libc.signal(libc.SIGINT, proc "cdecl" (_: i32) {
		context = on_interrupt_context
		server_shutdown(on_interrupt_server)
	})
}

@(private)
server_on_connection_close :: proc(using s: ^Server, c: ^Connection) {
	free(c.thread, conn_allocator)
	free(c, conn_allocator)
	delete_key(&s.conns, c.socket)
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
    New,     // Got client, waiting to service first request.
    Active,  // Servicing request.
    Idle,    // Waiting for next request.
	Closing, // Going to close, cleaning up.
    Closed,  // Fully closed.
}

Connection :: struct {
	server:    ^Server,
	socket_mu: sync.Mutex,
	socket:    net.TCP_Socket,
	curr_req:  ^Request,
	handler:   proc(^Request, ^Response),
	state:     Connection_State,
	thread:    ^thread.Thread,
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

// Calls handler for each of the requests coming in.
// Everything is allocated in the temp_allocator, and freed at the end of the request.
// If you need to keep data from either the Request or Response, you need to clone it.
conn_handle_reqs :: proc(c: ^Connection) -> net.Network_Error {
    // Make sure the connection is closed when we are returning.
    defer if c.state != .Closing && c.state != .Closed {
        connection_close(c)
    }

    stream := tcp_stream(c.socket)
    stream_reader := io.to_reader(stream)
    Requests: for {
        defer free_all(context.temp_allocator)

        // PERF: we shouldn't create a new scanner everytime.
        scanner: bufio.Scanner
        bufio.scanner_init(&scanner, stream_reader, context.temp_allocator)

        res: Response
        response_init(&res, c.socket, context.temp_allocator)

        req: Request
        request_init(&req, context.temp_allocator)
        c.curr_req = &req

		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
        rline_str, ok := scanner_scan_or_bad_req(&scanner, &res, c, .URI_Too_Long)
        if !ok do break;
        if rline_str == "" {
            rline_str, ok = scanner_scan_or_bad_req(&scanner, &res, c, .URI_Too_Long)
            if !ok do break;
        }

		c.state = .Active

		// Recipients of an invalid request-line SHOULD respond with either a
		// 400 (Bad Request) error or a 301 (Moved Permanently) redirect with
		// the request-target properly encoded.
		rline, lok := requestline_parse(rline_str, context.temp_allocator)
		if !lok {
            res.headers["Connection"] = "close"
			response_send_or_log(&res, c, .Bad_Request)
            break
		}
		req.line = rline

        // Might need to support more versions later.
        if rline.version.major != 1 || rline.version.minor < 1 {
            res.headers["Connection"] = "close"
            response_send_or_log(&res, c, .HTTP_Version_Not_Supported)
            break
        }

        // Keep parsing the request as line delimited headers until we get to an empty line.
		for line in scanner_scan_or_bad_req(&scanner, &res, c, .Request_Header_Fields_Too_Large) {
			// The first empty line denotes the end of the headers section.
			if line == "" {
				break
			}

			if _, ok := header_parse(&req.headers, line); !ok {
                res.headers["Connection"] = "close"
				response_send_or_log(&res, c, .Bad_Request)
				break Requests
			}
		}

        if !headers_validate(req) {
            res.headers["Connection"] = "close"
            response_send_or_log(&res, c, .Bad_Request)
            break
        }

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := req.headers["Expect"]; ok &&
		   expect == "100-continue" &&
		   c.server.opts.auto_expect_continue {

			res.status = .Continue
			if err := response_send(&res, c, context.temp_allocator); err != nil {
				log.warnf("could not send automatic 100 continue: %s", err)
			}

			if c.state == .Closing || c.state == .Closed {
				break
			}
		}

		req._body = scanner

		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target == "*" {
			res.status = .Ok
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			is_head := rline.method == .Head
			if is_head && c.server.opts.redirect_head_to_get {
				rline.method = .Get
			}

			c.handler(&req, &res)

			if is_head && c.server.opts.redirect_head_to_get {
				rline.method = .Head
			}
		}

        if err := response_send(&res, c, context.temp_allocator); err != nil {
            log.warnf("could not send response: %s", err)
        }

        if c.state == .Closing || c.state == .Closed {
            break
        }

		c.state = .Idle
    }
    return nil
}

@(private)
response_send_or_log :: proc(res: ^Response, conn: ^Connection, status: Status) {
    res.status = status
    if err := response_send(res, conn, context.temp_allocator); err != nil {
        log.warnf("could not send request response bcs error: %s", err)
    }
}

@(private)
scanner_scan_or_bad_req :: proc(s: ^bufio.Scanner, res: ^Response, conn: ^Connection, to_much: Status) -> (string, bool) {
    if !bufio.scanner_scan(s) {
        err := bufio.scanner_error(s)
        log.warnf("request scanner error: %s", err)

        res.status = .Bad_Request
        #partial switch ex in err {
        case bufio.Scanner_Extra_Error:
            #partial switch ex {
            case .Advanced_Too_Far, .Too_Long:
                res.status = to_much
            }
        }

        res.headers["Connection"] = "close"
        response_send_or_log(res, conn, res.status)
        return "", false
    }

    return bufio.scanner_text(s), true
}

