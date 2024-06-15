//+build !js
package nbio

import "core:net"
import "core:os"

On_Close :: #type proc(user: rawptr, ok: bool)

@private
empty_on_close :: proc(_: rawptr, _: bool) {}

close_raw :: #force_inline proc(io: ^IO, fd: Closable, user: rawptr = nil, callback: On_Close = empty_on_close) -> ^Completion {
	return _close(io, fd, user, callback)
}

On_Accept :: #type proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)

accept_raw :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	return _accept(io, socket, user, callback)
}

On_Connect :: #type proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error)

connect_raw :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) -> ^Completion {
	completion, err := _connect(io, endpoint, user, callback)
	if err != nil {
		callback(user, {}, err)
	}
	return completion
}

On_Recv :: #type proc(user: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)

recv_raw :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) -> ^Completion {
	return _recv(io, socket, buf, user, callback)
}

recv_all_raw :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) -> ^Completion {
	return _recv(io, socket, buf, user, callback, all = true)
}

On_Sent :: #type proc(user: rawptr, sent: int, err: net.Network_Error)

send_tcp_raw :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) -> ^Completion {
	return _send(io, socket, buf, user, callback)
}

send_udp_raw :: proc(
	io: ^IO,
	endpoint: net.Endpoint,
	socket: net.UDP_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
) -> ^Completion {
	return _send(io, socket, buf, user, callback, endpoint)
}

send_all_tcp_raw :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) -> ^Completion {
	return _send(io, socket, buf, user, callback, all = true)
}

send_all_udp_raw :: proc(
	io: ^IO,
	endpoint: net.Endpoint,
	socket: net.UDP_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
) -> ^Completion {
	return _send(io, socket, buf, user, callback, endpoint, all = true)
}

On_Read :: #type proc(user: rawptr, read: int, err: os.Errno)

read_raw :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) -> ^Completion {
	return _read(io, fd, nil, buf, user, callback)
}

read_all_raw :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) -> ^Completion {
	return _read(io, fd, nil, buf, user, callback, all = true)
}

read_at_raw :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) -> ^Completion {
	return _read(io, fd, offset, buf, user, callback)
}

read_at_all_raw :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) -> ^Completion {
	return _read(io, fd, offset, buf, user, callback, all = true)
}

On_Write :: #type proc(user: rawptr, written: int, err: os.Errno)

write_raw :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) -> ^Completion {
	return _write(io, fd, nil, buf, user, callback)
}

write_all_raw :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) -> ^Completion {
	return _write(io, fd, nil, buf, user, callback, true)
}

write_at_raw :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) -> ^Completion {
	return _write(io, fd, offset, buf, user, callback)
}

write_at_all_raw :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) -> ^Completion {
	return _write(io, fd, offset, buf, user, callback, true)
}

On_Poll :: #type proc(user: rawptr, event: Poll_Event)

poll_raw :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
	return _poll(io, fd, event, multi, user, callback)
}
