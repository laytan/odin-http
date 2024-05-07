// Package nbio/poly contains variants of the nbio procedures that use generic/poly data
// so users can avoid casts and use multiple arguments.
//
// Please reference the documentation in `nbio`.
//
// Intention is to import this like so `import nbio "nbio/poly"`
package poly

import "core:mem"
import "core:net"
import "core:os"
import "core:time"

import nbio ".."

// Because mem is only used inside the poly procs, the checker thinks we aren't using it.
_ :: mem

/// Re-export `nbio` stuff that is not wrapped in this package.

Completion          :: nbio.Completion
IO                  :: nbio.IO
init                :: nbio.init
tick                :: nbio.tick
num_waiting         :: nbio.num_waiting
destroy             :: nbio.destroy
open_socket         :: nbio.open_socket
open_and_listen_tcp :: nbio.open_and_listen_tcp
with_timeout        :: nbio.with_timeout
listen              :: nbio.listen
timeout_remove      :: nbio.timeout_remove
Completion          :: nbio.Completion
Closable            :: nbio.Closable
open                :: nbio.open
Whence              :: nbio.Whence
seek                :: nbio.seek
Poll_Event          :: nbio.Poll_Event
poll_remove         :: nbio.poll_remove

/// Timeout

timeout :: proc {
	timeout1,
	timeout2,
	timeout3,
}

timeout1 :: proc(io: ^nbio.IO, dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._timeout(io, dur, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

timeout2 :: proc(io: ^nbio.IO, dur: time.Duration, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._timeout(io, dur, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

timeout3 :: proc(io: ^nbio.IO, dur: time.Duration, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._timeout(io, dur, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Close

close :: proc {
	close_no_cb,
	close1,
	close2,
	close3,
}

close_no_cb :: proc(io: ^IO, fd: Closable) -> ^Completion {
	return nbio.close(io, fd)
}

close1 :: proc(io: ^IO, fd: Closable, p: $T, callback: $C/proc(p: T, ok: bool)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, ok)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

close2 :: proc(io: ^IO, fd: Closable, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, ok: bool)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, ok)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

close3 :: proc(io: ^IO, fd: Closable, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, ok: bool)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T3):]))^

		cb(p, p2, p3, ok)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Accept

accept :: proc {
	accept1,
	accept2,
	accept3,
}

accept1 :: proc(io: ^IO, socket: net.TCP_Socket, p: $T, callback: $C/proc(p: T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		completion := (^Completion)(completion)
		cb         := (^C)(&completion.user_args[0])^
		p          := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, client, source, err)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

accept2 :: proc(io: ^IO, socket: net.TCP_Socket, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, client, source, err)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

accept3 :: proc(io: ^IO, socket: net.TCP_Socket, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, client, source, err)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Connect

connect :: proc {
	connect1,
	connect2,
	connect3,
}

connect1 :: proc(io: ^IO, endpoint: net.Endpoint, p: $T, callback: $C/proc(p: T, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion, err := nbio._connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, socket, err)
	})
    if err != nil {
        callback(p, {}, err)
        return
    }

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

connect2 :: proc(io: ^IO, endpoint: net.Endpoint, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion, err := nbio._connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, socket, err)
	})
    if err != nil {
        callback(p, p2, {}, err)
        return
    }

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

connect3 :: proc(io: ^IO, endpoint: net.Endpoint, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion, err := nbio._connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, socket, err)
	})
    if err != nil {
        callback(p, p2, p3, {}, err)
        return nil
    }

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Internal Recv

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, all: bool, p: $T, callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, received, udp_client, err)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

_recv2 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, all: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, received, udp_client, err)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

_recv3 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, all: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, received, udp_client, err)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Recv

recv :: proc {
	recv1,
	recv2,
	recv3,
}

recv1 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _recv(io, socket, buf, false, p, callback)
}

recv2 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _recv2(io, socket, buf, false, p, p2, callback)
}

recv3 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _recv3(io, socket, buf, false, p, p2, p3, callback)
}

/// Recv All

recv_all :: proc {
	recv_all1,
	recv_all2,
	recv_all3,
}

recv_all1 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _recv(io, socket, buf, true, p, callback)
}

recv_all2 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _recv_all2(io, socket, buf, false, p, p2, callback)
}

recv_all3 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _recv_all2(io, socket, buf, false, p, p2, p3, callback)
}

/// Send

send :: proc {
	send_tcp1,
	send_tcp2,
	send_tcp3,
	send_udp1,
	send_udp2,
	send_udp3,
}

/// Send Internal

_send :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error), endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, sent, err)
	}, endpoint, all)

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

_send2 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error), endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, sent, err)
	}, endpoint, all)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

_send3 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error), endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, sent, err)
	}, endpoint, all)

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Send TCP

send_tcp1 :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _send(io, socket, buf, p, callback)
}

send_tcp2 :: proc(io: ^nbio.IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback)
}

send_tcp3 :: proc(io: ^nbio.IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback)
}

/// Send UDP

send_udp1 :: proc(io: ^nbio.IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _send(io, socket, buf, p, callback, endpoint)
}

send_udp2 :: proc(io: ^nbio.IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback, endpoint)
}

send_udp3 :: proc(io: ^nbio.IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback, endpoint)
}

/// Send All

send_all :: proc {
	send_all_tcp1,
	send_all_tcp2,
	send_all_tcp3,
	send_all_udp1,
	send_all_udp2,
	send_all_udp3,
}

/// Send All TCP

send_all_tcp1 :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _send(io, socket, buf, p, callback, all = true)
}

send_all_tcp2 :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback, all = true)
}

send_all_tcp3 :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback, all = true)
}

/// Send All UDP

send_all_udp1 :: proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _send(io, socket, buf, p, callback, endpoint, all = true)
}

send_all_udp2 :: proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback, endpoint, all = true)
}

send_all_udp3 :: proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback, endpoint, all = true)
}

/// Read Internal

_read :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._read(io, fd, offset, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, read, err)
	}, all)

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

_read2 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._read(io, fd, offset, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, read, err)
	}, all)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

_read3 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._read(io, fd, offset, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, read, err)
	}, all)

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Read

read :: proc {
	read1,
	read2,
	read3,
}

read1 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _read(io, fd, nil, buf, p, callback)
}

read2 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _read2(io, fd, nil, buf, p, p2, callback)
}

read3 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _read3(io, fd, nil, buf, p, p2, p3, callback)
}

/// Read All

read_all :: proc {
	read_all1,
	read_all2,
	read_all3,
}

read_all1 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _read(io, fd, nil, buf, p, callback, all = true)
}

read_all2 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _read2(io, fd, nil, buf, p, p2, callback, all = true)
}

read_all3 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _read3(io, fd, nil, buf, p, p2, p3, callback, all = true)
}

/// Read At

read_at :: proc {
	read_at1,
	read_at2,
	read_at3,
}

read_at1 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _read(io, fd, offset, buf, p, callback)
}

read_at2 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _read2(io, fd, offset, buf, p, p2, callback)
}

read_at3 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _read3(io, fd, offset, buf, p, p2, p3, callback)
}

/// Read At All

read_at_all :: proc {
	read_at_all1,
	read_at_all2,
	read_at_all3,
}

read_at_all1 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _read(io, fd, offset, buf, p, callback, all = true)
}

read_at_all2 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _read2(io, fd, offset, buf, p, p2, callback, all = true)
}

read_at_all3 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _read3(io, fd, offset, buf, p, p2, p3, callback, all = true)
}

/// Read Full / Entire File

read_entire_file :: read_full

read_full :: proc {
	read_full1,
	read_full2,
	read_full3,
}

read_full1 :: proc(io: ^IO, fd: os.Handle, p: $T, callback: $C/proc(p: T, buf: []byte, read: int, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of([]byte) <= nbio.MAX_USER_ARGUMENTS {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(p, nil, 0, err)
		return
	}

	if size <= 0 {
		callback(p, nil, 0, os.ERROR_NONE)
		return
	}

	buf := make([]byte, size, allocator)

	completion := nbio._read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb  := (^C)     (&completion.user_args[0])^
		buf := (^[]byte)(raw_data(completion.user_args[size_of(C):]))^
		p   := (^T)     (raw_data(completion.user_args[size_of(C) + size_of([]byte):]))^

		cb(p, buf, read, err)
	}, all = true)

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&buf))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

read_full2 :: proc(io: ^nbio.IO, fd: os.Handle, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, buf: []byte, read: int, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of(T2) + size_of([]byte) <= nbio.MAX_USER_ARGUMENTS {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(p, p2, nil, 0, err)
		return nil
	}

	if size <= 0 {
		callback(p, p2, nil, 0, os.ERROR_NONE)
		return nil
	}

	buf := make([]byte, size, allocator)

	completion := nbio._read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb  := (^C)     (&completion.user_args[0])^
		buf := (^[]byte)(raw_data(completion.user_args[size_of(C):]))^
		p   := (^T)     (raw_data(completion.user_args[size_of(C) + size_of([]byte):]))^
		p2  := (^T2)    (raw_data(completion.user_args[size_of(C) + size_of([]byte) + size_of(T):]))^

		cb(p, p2, buf, read, err)
	}, all = true)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&buf))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

read_full3 :: proc(io: ^nbio.IO, fd: os.Handle, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, buf: []byte, read: int, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) + size_of([]byte) <= nbio.MAX_USER_ARGUMENTS {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(p, p2, p3, nil, 0, err)
		return
	}

	if size <= 0 {
		callback(p, p2, p3, nil, 0, os.ERROR_NONE)
		return
	}

	buf := make([]byte, size, allocator)

	completion := nbio._read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb  := (^C)     (&completion.user_args[0])^
		buf := (^[]byte)(raw_data(completion.user_args[size_of(C):]))^
		p   := (^T)     (raw_data(completion.user_args[size_of(C) + size_of([]byte):]))^
		p2  := (^T2)    (raw_data(completion.user_args[size_of(C) + size_of([]byte) + size_of(T):]))^
		p3  := (^T3)    (raw_data(completion.user_args[size_of(C) + size_of([]byte) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, buf, read, err)
	}, all = true)

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&buf))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Write Internal

_write :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._write(io, fd, offset, buf, nil, proc(completion: rawptr, written: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, written, err)
	}, all)

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

_write2 :: proc(io: ^nbio.IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._write(io, fd, offset, buf, nil, proc(completion: rawptr, written: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, written, err)
	}, all)

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

_write3 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._write(io, fd, offset, buf, nil, proc(completion: rawptr, written: int, err: os.Errno) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, written, err)
	}, all)

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

/// Write

write :: proc {
	write1,
	write2,
	write3,
}

write1 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _write(io, fd, nil, buf, p, callback)
}

write2 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _write2(io, fd, nil, buf, p, p2, callback)
}

write3 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _write3(io, fd, nil, buf, p, p2, p3, callback)
}

/// Write All

write_all :: proc {
	write_all1,
	write_all2,
	write_all3,
}

write_all1 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _write(io, fd, nil, buf, p, callback, all = true)
}

write_all2 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _write2(io, fd, nil, buf, p, p2, callback, all = true)
}

write_all3 :: proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _write3(io, fd, nil, buf, p, p2, p3, callback, all = true)
}

/// Write At

write_at :: proc {
	write_at1,
	write_at2,
	write_at3,
}

write_at1 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _write(io, fd, offset, buf, p, callback)
}

write_at2 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _write2(io, fd, offset, buf, p, p2, callback)
}

write_at3 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _write3(io, fd, offset, buf, p, p2, p3, callback)
}

/// Write At All

write_at_all :: proc {
	write_at_all1,
	write_at_all2,
	write_at_all3,
}

write_at_all1 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	return _write(io, fd, offset, buf, p, callback, all = true)
}

write_at_all2 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	return _write2(io, fd, offset, buf, p, p2, callback, all = true)
}

write_at_all3 :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	return _write3(io, fd, offset, buf, p, p2, p3, callback, all = true)
}

next_tick1 :: proc(io: ^IO, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._next_tick(io, nil, proc(completion: rawptr) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

next_tick2 :: proc(io: ^nbio.IO, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._next_tick(io, nil, proc(completion: rawptr) {
		completion := (^nbio.Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

next_tick3 :: proc(io: ^IO, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._next_tick(io, nil, proc(completion: rawptr) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

next_tick :: proc {
	next_tick1,
	next_tick2,
	next_tick3,
}

poll1 :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, p: $T, callback: $C/proc(p: T, event: Poll_Event)) -> ^Completion
	where size_of(T) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._poll(io, fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^

		cb(p, event)
	})

	callback, p := callback, p
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

	completion.user_data = completion
	return completion
}

poll2 :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, event: Poll_Event)) -> ^Completion
	where size_of(T) + size_of(T2) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._poll(io, fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		completion := (^Completion)(completion)

		cb := (^C)(&completion.user_args[0])^
		p  := (^T)(raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^

		cb(p, p2, event)
	})

	callback, p, p2 := callback, p, p2
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

	completion.user_data = completion
	return completion
}

poll3 :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, event: Poll_Event)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= nbio.MAX_USER_ARGUMENTS {
	completion := nbio._poll(io, fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		completion := (^Completion)(completion)

		cb := (^C) (&completion.user_args[0])^
		p  := (^T) (raw_data(completion.user_args[size_of(C):]))^
		p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
		p3 := (^T3)(raw_data(completion.user_args[size_of(C) + size_of(T) + size_of(T2):]))^

		cb(p, p2, p3, event)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	n := copy(completion.user_args[:],  mem.ptr_to_bytes(&callback))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
	n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))
	_  = copy(completion.user_args[n:], mem.ptr_to_bytes(&p3))

	completion.user_data = completion
	return completion
}

poll :: proc {
	poll1,
	poll2,
	poll3,
}
