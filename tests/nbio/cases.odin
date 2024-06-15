package tests_nbio

import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:time"

import "../../nbio"

get_endpoint :: proc() -> net.Endpoint {
	@static mu: sync.Mutex
	sync.guard(&mu)

	PORT_START :: 3000
	@static port: int
	if port == 0 {
		port = PORT_START
	}

	port += 1
	return {net.IP4_Loopback, port}
}

@(test)
close_invalid_handle_works :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	nbio.close(&io, os.INVALID_HANDLE, t, proc(t: ^testing.T, ok: bool) {
		ev(t, ok, false)
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)
}

@(test)
timeout_runs_in_reasonable_time :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	start := time.now()

	nbio.timeout(&io, time.Millisecond * 10, rawptr(nil), proc(_: rawptr) {})

	ev(t, nbio.run(&io), os.ERROR_NONE)

	duration := time.since(start)
	e(t, duration < time.Millisecond * 11)
}

@(test)
write_read_close :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	handle, errno := nbio.open(
		&io,
		"test_write_read_close",
		os.O_RDWR | os.O_CREATE | os.O_TRUNC,
		os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH when ODIN_OS != .Windows else 0,
	)
	ev(t, errno, os.ERROR_NONE)

	State :: struct {
		buf: [20]byte,
		fd:  os.Handle,
	}

	CONTENT :: [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}

	state := State{
		buf = CONTENT,
		fd = handle,
	}

	nbio.write_entire_file(&io, handle, state.buf[:], &io, t, &state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, written: int, err: os.Errno) {
		ev(t, written, len(state.buf))
		ev(t, err, os.ERROR_NONE)

		nbio.read_at_all(io, state.fd, 0, state.buf[:], io, t, state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, read: int, err: os.Errno) {
			ev(t, read, len(state.buf))
			ev(t, err, os.ERROR_NONE)
			ev(t, state.buf, CONTENT)

			nbio.close(io, state.fd, io, t, state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, ok: bool) {
				ev(t, ok, true)
				os.remove("test_write_read_close")
			})
		})
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)
}

@(test)
client_and_server_send_recv :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	EP := get_endpoint()

	server, err := nbio.open_and_listen_tcp(&io, EP)
	ev(t, err, nil)

	CONTENT :: [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}

	State :: struct {
		server:        net.TCP_Socket,
		server_client: net.TCP_Socket,
		client:        net.TCP_Socket,
		recv_buf:      [20]byte,
		send_buf:      [20]byte,
	}

	state := State{
		server   = server,
		send_buf = CONTENT,
	}

	close_ok :: proc(t: ^testing.T, ok: bool) {
		ev(t, ok, true)
	}

	nbio.accept(&io, server, &io, t, &state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, err, nil)

		state.server_client = client

		nbio.recv_all(io, client, state.recv_buf[:], io, t, state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
			ev(t, err, nil)
			ev(t, received, 20)
			ev(t, state.recv_buf, CONTENT)

			nbio.close(io, state.server_client, t, close_ok)
			nbio.close(io, state.server, t, close_ok)
		})
	})

	ev(t, nbio.tick(&io), os.ERROR_NONE)

	nbio.connect(&io, EP, &io, t, &state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)

		state.client = socket

		nbio.send_all(io, socket, state.send_buf[:], io, t, state, proc(io: ^nbio.IO, t: ^testing.T, state: ^State, sent: int, err: net.Network_Error) {
			ev(t, err, nil)
			ev(t, sent, 20)

			nbio.close(io, state.client, t, close_ok)
		})
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)
}

@(test)
close_and_remove_accept :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	server, err := nbio.open_and_listen_tcp(&io, get_endpoint())
	ev(t, err, nil)

	accept := nbio.accept(&io, server, t, proc(t: ^testing.T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		testing.fail_now(t)
	})

	ev(t, nbio.tick(&io), os.ERROR_NONE)

	nbio.close(&io, server, t, proc(t: ^testing.T, ok: bool) {
		ev(t, ok, true)
	})

	nbio.remove(&io, accept)

	ev(t, nbio.run(&io), os.ERROR_NONE)
}

@(test)
close_errors_recv :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	EP := get_endpoint()

	server, err := nbio.open_and_listen_tcp(&io, EP)
	ev(t, err, nil)

	nbio.accept(&io, server, t, &io, proc(t: ^testing.T, io: ^nbio.IO, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, err, nil)
		bytes := make([]byte, 128, context.temp_allocator)
		nbio.recv(io, client, bytes, t, proc(t: ^testing.T, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
			ev(t, received, 0)
			ev(t, err, nil)
		})
	})

	ev(t, nbio.tick(&io), os.ERROR_NONE)

	nbio.connect(&io, EP, t, &io, proc(t: ^testing.T, io: ^nbio.IO, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)
		nbio.close(io, socket, t, proc(t: ^testing.T, ok: bool) {
			ev(t, ok, true)
		})
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)
}

@(test)
close_errors_send :: proc(t: ^testing.T) {
	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	EP := get_endpoint()

	server, err := nbio.open_and_listen_tcp(&io, EP)
	ev(t, err, nil)

	nbio.accept(&io, server, t, &io, proc(t: ^testing.T, io: ^nbio.IO, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, err, nil)
		bytes := make([]byte, mem.Megabyte * 100, context.temp_allocator)
		nbio.send_all(io, client, bytes, t, proc(t: ^testing.T, sent: int, err: net.Network_Error) {
			ev(t, sent < mem.Megabyte * 100, true)
			ev(t, err, net.TCP_Send_Error.Connection_Closed)
		})
	})

	ev(t, nbio.tick(&io), os.ERROR_NONE)

	nbio.connect(&io, EP, t, &io, proc(t: ^testing.T, io: ^nbio.IO, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, err, nil)
		nbio.close(io, socket, t, proc(t: ^testing.T, ok: bool) {
			ev(t, ok, true)
		})
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)
}
