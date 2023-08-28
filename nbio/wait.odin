//+private
package nbio

import "core:net"
import "core:os"
import "core:time"

// INITIAL EXPERIMENTAL AND ALL OTHER WORDS TO SAY THIS IS NOT FINAL.
// DOESN'T REALLY WORK AT ALL ON SOME PLATFORMS (RANDOM ERRORS) BUT WOULD BE NICE.

accept_and_wait :: proc(
	io: ^IO,
	socket: net.TCP_Socket,
) -> (
	client: net.TCP_Socket,
	source: net.Endpoint,
	err: net.Network_Error,
) {
	Accept_Result :: struct {
		done:   bool,
		client: net.TCP_Socket,
		source: net.Endpoint,
		err:    net.Network_Error,
	}

	result: Accept_Result

	_accept(
		io,
		socket,
		&result,
		proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
			result := cast(^Accept_Result)user
			result.done = true
			result.client = client
			result.source = source
			result.err = err
		},
	)

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.client, result.source, result.err
}

//

close_and_wait :: proc(io: ^IO, fd: Closable) -> bool {
	Close_Result :: struct {
		done: bool,
		ok:   bool,
	}

	result: Close_Result

	_close(io, fd, &result, proc(user: rawptr, ok: bool) {
		result := cast(^Close_Result)user
		result.done = true
		result.ok = ok
	})

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.ok
}

//

connect_and_wait :: proc(io: ^IO, endpoint: net.Endpoint) -> (socket: net.TCP_Socket, err: net.Network_Error) {
	Connect_Result :: struct {
		done:   bool,
		socket: net.TCP_Socket,
		err:    net.Network_Error,
	}

	result: Connect_Result

	_connect(io, endpoint, &result, proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		result := cast(^Connect_Result)user
		result.done = true
		result.socket = socket
		result.err = err
	})

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.socket, result.err
}

//

@(private)
internal_read_and_wait :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte) -> (read: int, err: os.Errno) {
	Read_Result :: struct {
		done: bool,
		read: int,
		err:  os.Errno,
	}

	result: Read_Result

	_read(io, fd, offset, buf, &result, proc(user: rawptr, read: int, err: os.Errno) {
		result := cast(^Read_Result)user
		result.done = true
		result.read = read
		result.err = err
	})

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.read, result.err
}

read_and_wait :: proc(io: ^IO, fd: os.Handle, buf: []byte) -> (read: int, err: os.Errno) {
	return internal_read_and_wait(io, fd, nil, buf)
}

read_at_and_wait :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte) -> (read: int, err: os.Errno) {
	return internal_read_and_wait(io, fd, offset, buf)
}

//

@(private)
internal_recv_and_wait :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
) -> (
	received: int,
	client: Maybe(net.Endpoint),
	err: net.Network_Error,
) {
	Recv_Result :: struct {
		done:     bool,
		received: int,
		client:   Maybe(net.Endpoint),
		err:      net.Network_Error,
	}

	result: Recv_Result

	_recv(
		io,
		socket,
		buf,
		&result,
		proc(user: rawptr, received: int, client: Maybe(net.Endpoint), err: net.Network_Error) {
			result := cast(^Recv_Result)user
			result.done = true
			result.err = err
			result.client = client
			result.received = received
		},
	)

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.received, result.client, result.err
}

recv_tcp_and_wait :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte) -> (received: int, err: net.Network_Error) {
	received, _, err = internal_recv_and_wait(io, socket, buf)
	return
}

recv_udp_and_wait :: proc(
	io: ^IO,
	socket: net.UDP_Socket,
	buf: []byte,
) -> (
	received: int,
	client: net.Endpoint,
	err: net.Network_Error,
) {
	mc: Maybe(net.Endpoint)
	received, mc, err = internal_recv_and_wait(io, socket, buf)
	return received, mc.?, err
}

recv_and_wait :: proc {
	recv_tcp_and_wait,
	recv_udp_and_wait,
}

//

@(private)
internal_send_and_wait :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	endpoint: Maybe(net.Endpoint) = nil,
) -> (
	sent: int,
	err: net.Network_Error,
) {
	Send_Result :: struct {
		done: bool,
		sent: int,
		err:  net.Network_Error,
	}

	result: Send_Result

	_send(io, socket, buf, &result, proc(user: rawptr, sent: int, err: net.Network_Error) {
			result := cast(^Send_Result)user
			result.done = true
			result.sent = sent
			result.err = err
		}, endpoint)

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.sent, result.err
}

@(private)
internal_send_all_and_wait :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	endpoint: Maybe(net.Endpoint) = nil,
) -> (
	sent: int,
	err: net.Network_Error,
) {
	for sent < len(buf) {
		sent += internal_send_and_wait(io, socket, buf[sent:], endpoint) or_return
	}
	return
}

send_tcp_and_wait :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte) -> (sent: int, err: net.Network_Error) {
	return internal_send_and_wait(io, socket, buf)
}

send_tcp_all_and_wait :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte) -> (sent: int, err: net.Network_Error) {
	return internal_send_all_and_wait(io, socket, buf)
}

send_udp_and_wait :: proc(
	io: ^IO,
	socket: net.UDP_Socket,
	endpoint: net.Endpoint,
	buf: []byte,
) -> (
	sent: int,
	err: net.Network_Error,
) {
	return internal_send_and_wait(io, socket, buf, endpoint)
}

send_udp_all_and_wait :: proc(
	io: ^IO,
	socket: net.UDP_Socket,
	endpoint: net.Endpoint,
	buf: []byte,
) -> (
	sent: int,
	err: net.Network_Error,
) {
	return internal_send_all_and_wait(io, socket, buf, endpoint)
}

send_and_wait :: proc {
	send_tcp_and_wait,
	send_udp_and_wait,
}

send_all_and_wait :: proc {
	send_tcp_all_and_wait,
	send_udp_all_and_wait,
}

//

@(private)
internal_write_and_wait :: proc(
	io: ^IO,
	fd: os.Handle,
	buf: []byte,
	offset: Maybe(int) = nil,
) -> (
	written: int,
	err: os.Errno,
) {
	Write_Result :: struct {
		done:    bool,
		written: int,
		err:     os.Errno,
	}

	result: Write_Result

	_write(io, fd, offset, buf, &result, proc(user: rawptr, written: int, err: os.Errno) {
		result := cast(^Write_Result)user
		result.done = true
		result.written = written
		result.err = err
	})

	for !result.done {
		assert(tick(io) == os.ERROR_NONE)
	}

	return result.written, result.err
}

@(private)
internal_write_all_and_wait :: proc(
	io: ^IO,
	fd: os.Handle,
	buf: []byte,
	offset: Maybe(int) = nil,
) -> (
	written: int,
	err: os.Errno,
) {
	for written < len(buf) {
		off: Maybe(int) = offset if offset == nil else offset.? + written
		iwrote, ierr := internal_write_and_wait(io, fd, buf[written:], off)
		if ierr != os.ERROR_NONE {
			err = ierr
			return
		}
		written += iwrote
	}
	return
}

write_and_wait :: proc(io: ^IO, fd: os.Handle, buf: []byte) -> (written: int, err: os.Errno) {
	return internal_write_and_wait(io, fd, buf)
}

write_at_and_wait :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte) -> (written: int, err: os.Errno) {
	return internal_write_and_wait(io, fd, buf, offset)
}

write_all_and_wait :: proc(io: ^IO, fd: os.Handle, buf: []byte) -> (written: int, err: os.Errno) {
	return internal_write_all_and_wait(io, fd, buf)
}

write_at_all_and_wait :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte) -> (written: int, err: os.Errno) {
	return internal_write_all_and_wait(io, fd, buf, offset)
}

//

timeout_and_wait :: proc(io: ^IO, dur: time.Duration) {
	done: bool

	_timeout(io, dur, &done, proc(user: rawptr) {
		done := cast(^bool)user
		done^ = true
	})

	for !done {
		assert(tick(io) == os.ERROR_NONE)
	}
}
