package nbio

import "core:os"
import "core:net"
import "core:time"

_IO :: struct {}

_init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	// panic("TODO")
	return
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	panic("TODO")
}

_destroy :: proc(io: ^IO) {
	panic("TODO")
}

_tick :: proc(io: ^IO) -> os.Errno {
	panic("TODO")
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	panic("TODO")
}

// TODO: We could have completions hold a pointer to the IO so it doesn't need to be passed here.
_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	panic("TODO")
}

_timeout_remove :: proc(io: ^IO, timeout: ^Completion) {
	panic("TODO")
}

_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	panic("TODO")
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	panic("core:nbio procedure not supported on js target")
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) -> (^Completion, net.Network_Error) {
	panic("core:nbio procedure not supported on js target")
}

_read :: proc(
	io: ^IO,
	fd: os.Handle,
	offset: Maybe(int),
	buf: []byte,
	user: rawptr,
	callback: On_Read,
	all := false,
) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_write :: proc(
	io: ^IO,
	fd: os.Handle,
	offset: Maybe(int),
	buf: []byte,
	user: rawptr,
	callback: On_Write,
	all := false,
) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_poll :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, user: rawptr, callback: On_Poll) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_poll_remove :: proc(io: ^IO, fd: os.Handle, event: Poll_Event) -> ^Completion {
	panic("core:nbio procedure not supported on js target")
}

_seek :: proc(_: ^IO, fd: os.Handle, offset: int, whence: Whence) -> (int, os.Errno) {
	panic("core:nbio procedure not supported on js target")
}

_open :: proc(_: ^IO, path: string, mode, perm: int) -> (handle: os.Handle, errno: os.Errno) {
	panic("core:nbio procedure not supported on js target")
}

_open_socket :: proc(
	_: ^IO,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	panic("core:nbio procedure not supported on js target")
}

Op_Accept :: struct { }

Op_Close :: struct {}

Op_Connect :: struct {}

Op_Recv :: struct {}

Op_Send :: struct {}

Op_Read :: struct {}

Op_Write :: struct {}

Op_Timeout :: struct {}

Op_Next_Tick :: struct {}

Op_Poll :: struct {}

Op_Poll_Remove :: struct {}

Op_Remove :: struct {}

_Completion :: struct {}
