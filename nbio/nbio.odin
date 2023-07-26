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

// TODO: set LINGER option?
//
// Prepares a socket for non blocking IO,
// user should call this before passing the socket to any other nbio procs.
//
// Sockets returned/created from nbio (accept() for example) are prepared by nbio.
prepare_socket :: proc(socket: net.Any_Socket) -> net.Network_Error {
	_ = net.set_option(socket, .Reuse_Address, true)
	_ = net.set_option(socket, .TCP_Nodelay, true)
	net.set_blocking(socket, false) or_return
	return nil
}

// Prepares a handle for non blocking IO,
// user should call this before passing the handle to any other nbio procs.
prepare_handle :: proc(handle: Handle) -> net.Network_Error {
	// NOTE: TCP_Socket gets cast to int right away in net, so this is safe to do.
	return net.set_blocking(net.TCP_Socket(handle), true)
}

prepare :: proc {
	prepare_socket,
	prepare_handle,
}

On_Accept :: proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)

accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	_accept(io, socket, user, callback)
}

On_Close :: proc(user: rawptr, ok: bool)

close :: proc(io: ^IO, fd: Handle, user: rawptr, callback: On_Close) {
	_close(io, fd, user, callback)
}

On_Connect :: proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error)

connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	_connect(io, endpoint, user, callback)
}

On_Read :: proc(user: rawptr, read: int, err: os.Errno)

read :: proc(io: ^IO, fd: Handle, buf: []byte, user: rawptr, callback: On_Read) {
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

write :: proc(io: ^IO, fd: Handle, buf: []byte, user: rawptr, callback: On_Write) {
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
