package nbio

import "core:os"
import "core:time"
import "core:net"

@(private)
DEFAULT_ENTRIES :: 32

@(private)
NANOSECONDS_PER_SECOND :: 1e+9

IO :: struct {
	impl_data: rawptr,
}

init :: proc(
	io: ^IO,
	entries: u32 = DEFAULT_ENTRIES,
	flags: u32 = 0,
	allocator := context.allocator,
) -> (
	err: os.Errno,
) {
	return _init(io, entries, flags, allocator)
}

destroy :: proc(io: ^IO) {
	_destroy(io)
}

tick :: proc(io: ^IO) -> os.Errno {
	return _tick(io)
}

// Opens a file hande, sets non blocking mode and relates it to the given IO.
open :: proc(io: ^IO, path: string, mode: int = os.O_RDONLY, perm: int = 0) -> (os.Handle, os.Errno) {
	return _open(io, path, mode, perm)
}

// Creates a socket, sets non blocking mode and relates it to the given IO.
open_socket :: proc(io: ^IO, family: net.Address_Family, protocol: net.Socket_Protocol) -> (net.Any_Socket, net.Network_Error) {
	return _open_socket(io, family, protocol)
}

open_and_listen_tcp :: proc(io: ^IO, ep: net.Endpoint) -> (socket: net.TCP_Socket, err: net.Network_Error) {
	family: net.Address_Family
	switch _ in ep.address {
	case net.IP4_Address: family = .IP4
	case net.IP6_Address: family = .IP6
	}

	sock := open_socket(io, family, .TCP) or_return
	if err = listen(socket); err != nil do net.close(sock)
	return
}

// Not a non-blocking call,
// but provided for convenience because net.listen_tcp does more than just listening.
// and os.listen is not there in windows.
listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	return _listen(socket, backlog)
}

On_Accept :: proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)

accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	_accept(io, socket, user, callback)
}

On_Close :: proc(user: rawptr, ok: bool)

close :: proc(io: ^IO, fd: os.Handle, user: rawptr, callback: On_Close) {
	_close(io, fd, user, callback)
}

On_Connect :: proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error)

connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	_connect(io, endpoint, user, callback)
}

On_Read :: proc(user: rawptr, read: int, err: os.Errno)

// TODO: accept and use offset.
read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	_read(io, fd, buf, user, callback)
}

// udp_remote is set if the socket is a UDP socket.
On_Recv :: proc(user: rawptr, received: int, udp_remote: net.Endpoint, err: net.Network_Error)

recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	_recv(io, socket, buf, user, callback)
}

On_Sent :: proc(user: rawptr, sent: int, err: net.Network_Error)

// set endpoint if the socket is a UDP socket.
send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
) {
	_send(io, socket, buf, user, callback)
}

On_Write :: proc(user: rawptr, written: int, err: os.Errno)

write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	_write(io, fd, buf, user, callback)
}

On_Timeout :: proc(user: rawptr)

timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	_timeout(io, dur, user, callback)
}

@(private)
Operation :: union #no_nil {
	Op_Accept,
	Op_Close,
	Op_Connect,
	Op_Read,
	Op_Recv,
	Op_Send,
	Op_Write,
	Op_Timeout,
}
