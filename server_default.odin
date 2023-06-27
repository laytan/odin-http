//+private
//+build !darwin
package http

import "core:io"
import "core:log"
import "core:net"
import "core:sync"
import "core:thread"
import "core:time"

Default_Server_Connection :: struct {
	thread:    thread.Thread,
	socket_mu: sync.Mutex,
	reader:    io.Reader,
}

_server_serve :: proc(using s: ^Server) -> net.Network_Error {
	for {
		// Don't accept more connections when we are shutting down,
		// but we don't want to return yet, this way users can wait for this
		// proc to return as well as the shutdown proc.
		if shutting_down {
			time.sleep(SHUTDOWN_INTERVAL)
			continue
		}

		if shut_down do break

		c := new(Connection, conn_allocator)
		c.impl_data = dc
		c.state = .Pending
		c.server = s
		c.handler = handler

		dc := new(Default_Server_Connection, conn_allocator)
		dc.socket_mu = sync.Mutex{}
		sync.mutex_lock(&dc.socket_mu)

		// Each connection has its own thread. This has to be the case because
		// sockets are blocking in the 'net' package of Odin.
		//
		// We use the mutex so we can start a thread before accepting the connection,
		// this way, the first request of a connection does not have to wait for
		// the thread to spin up.
		dc.thread = thread.create_and_start_with_poly_data2(
			c,
			dc,
			proc(c: ^Connection, dc: ^Default_Server_Connection) {
				// Will block until main thread unlocks the mutex, indicating a connection is ready.
				sync.mutex_lock(&dc.socket_mu)

				c.state = .New
				if err := conn_handle_reqs(c); err != nil {
					log.errorf("connection error: %s", err)
				}
			},
			context,
		)

		socket, client, err := net.accept_tcp(s.tcp_sock)
		if err != nil {
			free(c.thread)
			free(c)
			return err
		}

		c.socket = socket
		c.client = client

		log.infof("new connection with %v, got %i open connections", client.address, len(conns))

		conns[socket] = c

		dc.reader = io.to_reader(tcp_stream(c.socket))

		sync.mutex_unlock(&dc.socket_mu)
	}

	return nil
}

_server_on_conn_close :: proc(s: ^Server, c: ^Connection) {
	dc := cast(^Default_Server_Connection)c.impl_data
	free(dc.thread, s.conn_allocator)
}

_server_shutdown :: proc(s: ^Server) {}

_scanner_read :: proc(s: ^Scanner, buf: []byte) {
	dc := cast(^Default_Server_Connection)s.connection.impl_data
	n, err := io.read(dc.reader, buf)
	scanner_on_read(s, n, err)
}

_send_response :: proc(
	c: ^Connection,
	buf: []byte,
	will_close: ^bool,
	callback: Send_Response_Callback,
	allocator := context.allocator,
) {
	_, err := net.send_tcp(c.socket, buf)
	callback(c, will_close, err, allocator)
}
