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

Op_Accept :: struct {
	socket: os.Socket,
	addr: os.SOCKADDR_STORAGE_LH,
	addr_len: os.socklen_t,
}

Accept_Callback :: proc(
	user_data: rawptr,
	sock: os.Socket, // TODO: remove.
	addr: os.SOCKADDR_STORAGE_LH,
	addr_len: os.socklen_t,
	err: os.Errno,
)

accept :: proc(io: ^IO, socket: os.Socket, user_data: rawptr, callback: Accept_Callback) {
	_accept(io, socket, user_data, callback)
}

Op_Close :: struct {
	fd: os.Handle,
}

Close_Callback :: proc(user_data: rawptr, ok: bool)

close :: proc(io: ^IO, fd: os.Handle, user_data: rawptr, callback: Close_Callback) {
	_close(io, fd, user_data, callback)
}

Op_Connect :: struct {
	socket:    os.Socket, // TODO: remove?
	addr:      ^os.SOCKADDR,
	len:       os.socklen_t,
	initiated: bool,
}

Connect_Callback :: proc(user_data: rawptr, sock: os.Socket, err: os.Errno)

connect :: proc(io: ^IO, op: Op_Connect, user_data: rawptr, callback: Connect_Callback) {
	_connect(io, op, user_data, callback)
}

Op_Read :: struct {
	fd:     os.Handle,
	buf:    []byte,
	offset: i64,
}

Read_Callback :: proc(user_data: rawptr, read: int, err: os.Errno)

read :: proc(io: ^IO, op: Op_Read, user_data: rawptr, callback: Read_Callback) {
	_read(io, op, user_data, callback)
}

Op_Recv :: struct {
	socket: os.Socket,
	buf:    []byte,
	flags:  int,
}

Recv_Callback :: proc(user_data: rawptr, buf: []byte, received: u32, err: os.Errno)

recv :: proc(io: ^IO, op: Op_Recv, user_data: rawptr, callback: Recv_Callback) {
	_recv(io, op, user_data, callback)
}

Op_Send :: struct {
	socket: os.Socket,
	buf:    []byte,
	flags:  int,
}

Send_Callback :: proc(user_data: rawptr, sent: u32, err: os.Errno)

send :: proc(io: ^IO, op: Op_Send, user_data: rawptr, callback: Send_Callback) {
	_send(io, op, user_data, callback)
}

Op_Write :: struct {
	fd:     os.Handle,
	buf:    []byte,
	offset: i64,
}

Write_Callback :: proc(user_data: rawptr, written: int, err: os.Errno)

write :: proc(io: ^IO, op: Op_Write, user_data: rawptr, callback: Write_Callback) {
	_write(io, op, user_data, callback)
}

Op_Timeout :: struct {
	expires: time.Time,
}

Timeout_Callback :: proc(user_data: rawptr)

timeout :: proc(io: ^IO, dur: time.Duration, user_data: rawptr, callback: Timeout_Callback) {
	_timeout(io, dur, user_data, callback)
}
