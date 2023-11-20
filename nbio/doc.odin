/*
package nbio implements a non blocking IO abstraction layer over several platform specific APIs.

This package implements an event loop based abstraction.

APIs:
- Windows: [[IOCP IO Completion Ports;https://en.wikipedia.org/wiki/Input/output_completion_port]]
- Linux:   [[io_uring;https://en.wikipedia.org/wiki/Io_uring]]
- Darwin:  [[KQueue;https://en.wikipedia.org/wiki/Kqueue]]

How to read the code:

The file nbio.odin can be read a little bit like a header file,
it has all the procedures heavily explained and commented and dispatches them to platform specific code.

You can also have a look at the tests for more general usages.

Example:
	/*
	This example shows a simple TCP server that echos back anything it receives.

	Better error handling and closing/freeing connections are left for the reader.
	*/
	package main

	import "core:fmt"
	import "core:net"
	import "core:os"

	import nbio "nbio/poly"

	Echo_Server :: struct {
		io:          nbio.IO,
		sock:        net.TCP_Socket,
		connections: [dynamic]^Echo_Connection,
	}

	Echo_Connection :: struct {
		server:  ^Echo_Server,
		sock:    net.TCP_Socket,
		buf:     [50]byte,
	}

	main :: proc() {
		server: Echo_Server
		defer delete(server.connections)

		nbio.init(&server.io)
		defer nbio.destroy(&server.io)

		sock, err := nbio.open_and_listen_tcp(&server.io, {net.IP4_Loopback, 8080})
		fmt.assertf(err == nil, "Error opening and listening on localhost:8080: %v", err)
		server.sock = sock

		nbio.accept(&server.io, sock, &server, echo_on_accept)

		// Start the event loop.
		errno: os.Errno
		for errno == os.ERROR_NONE {
			errno = nbio.tick(&server.io)
		}

		fmt.assertf(errno == os.ERROR_NONE, "Server stopped with error code: %v", errno)
	}

	echo_on_accept :: proc(server: ^Echo_Server, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		fmt.assertf(err == nil, "Error accepting a connection: %v", err)

		// Register a new accept for the next client.
		nbio.accept(&server.io, server.sock, server, echo_on_accept)

		c := new(Echo_Connection)
		c.server = server
		c.sock   = client
		append(&server.connections, c)

		nbio.recv(&server.io, client, c.buf[:], c, echo_on_recv)
	}

	echo_on_recv :: proc(c: ^Echo_Connection, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
		fmt.assertf(err == nil, "Error receiving from client: %v", err)

		nbio.send_all(&c.server.io, c.sock, c.buf[:received], c, echo_on_sent)
	}

	echo_on_sent :: proc(c: ^Echo_Connection, sent: int, err: net.Network_Error) {
		fmt.assertf(err == nil, "Error sending to client: %v", err)

		// Accept the next message, to then ultimately echo back again.
		nbio.recv(&c.server.io, c.sock, c.buf[:], c, echo_on_recv)
	}
*/
package nbio
