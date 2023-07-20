package nbio

import "core:os"
import "core:time"
import "core:net"

@(private)
DEFAULT_ENTRIES :: 32

@(private)
NANOSECONDS_PER_SECOND :: 1e+9

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

IO :: struct {
	impl_data: rawptr,
}

init :: proc(io: ^IO, entries: u32 = DEFAULT_ENTRIES, flags: u32 = 0, allocator := context.allocator) -> (err: os.Errno) {
	return _init(io, entries, flags, allocator)
}

destroy :: proc(io: ^IO) {
	_destroy(io)
}

tick :: proc(io: ^IO) -> os.Errno {
	return _tick(io)
}

// TODO: set LINGER option.
prepare_socket :: proc(socket: net.Any_Socket) -> net.Network_Error {
	return _prepare_socket(socket)
}

On_Accept :: proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)

accept :: proc(io: ^IO, socket: net.Tcp_Socket, user: rawptr, callback: On_Accept) {
	_accept(io, socket, user, callback)
}

On_Close :: proc(user: rawptr, ok: bool)

close :: proc(io: ^IO, fd: Handle, user: rawptr, callback: On_Close) {
	_close(io, fd, user, callback)
}

// Op_Connect :: struct {
// 	socket:    os.Socket,
// 	addr:      os.SOCKADDR_STORAGE_LH,
// 	addr_len:  os.socklen_t,
// 	initiated: bool,
// }

On_Connect :: proc(user: rawptr, err: net.Network_Error)

connect :: proc(io: ^IO, socket: net.Tcp_Socket, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	_connect(io, socket, endpoint, user, callback)
}

// Op_Read :: struct {
// 	fd:     os.Handle,
// 	buf:    []byte,
// 	offset: i64,
// }

On_Read :: proc(user: rawptr, read: int, err: os.Errno)

read :: proc(io: ^IO, fd: Handle, buf: []byte, user: rawptr, callback: On_Read) {
	_read(io, fd, buf, user, callback)
}

// Op_Recv :: struct {
// 	socket: os.Socket,
// 	buf:    []byte,
// 	flags:  int, // TODO: remove?
// }

On_Recv :: proc(user: rawptr, received: int, err: net.Network_Error)

recv :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	_recv(io, socket, buf, user, callback)
}

// Op_Send :: struct {
// 	socket: os.Socket,
// 	buf:    []byte,
// 	flags:  int,
// }

On_Sent :: proc(user: rawptr, sent: int, err: net.Network_Error)

send :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {
	_send(io, socket, buf, user, callback)
}

// Op_Write :: struct {
// 	fd:     os.Handle,
// 	buf:    []byte,
// 	offset: i64,
// }

On_Write :: proc(user: rawptr, written: int, err: os.Errno)

write :: proc(io: ^IO, fd: Handle, buf: []byte, user: rawptr, callback: On_Write) {
	_write(io, fd, buf, user, callback)
}

// Op_Timeout :: struct {
// 	expires: time.Time,
// }

// TODO: probably error too.
On_Timeout :: proc(user: rawptr)

timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	_timeout(io, dur, user, callback)
}
