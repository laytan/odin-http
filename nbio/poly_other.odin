//+build !js
package nbio

import "base:intrinsics"

import "core:net"
import "core:os"

close1 :: proc(io: ^IO, fd: Closable, p: $T, callback: $C/proc(p: T, ok: bool)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, ok)
	})

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

close2 :: proc(io: ^IO, fd: Closable, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, ok: bool)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, ok)
	})

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

close3 :: proc(io: ^IO, fd: Closable, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, ok: bool)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _close(io, fd, nil, proc(completion: rawptr, ok: bool) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, ok)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

accept1 :: proc(io: ^IO, socket: net.TCP_Socket, p: $T, callback: $C/proc(p: T, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, client, source, err)
	})

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

accept2 :: proc(io: ^IO, socket: net.TCP_Socket, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, client, source, err)
	})

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

accept3 :: proc(io: ^IO, socket: net.TCP_Socket, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _accept(io, socket, nil, proc(completion: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, client, source, err)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

connect1 :: proc(io: ^IO, endpoint: net.Endpoint, p: $T, callback: $C/proc(p: T, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion, err := _connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, socket, err)
	})
    if err != nil {
        callback(p, {}, err)
        return completion
    }

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

connect2 :: proc(io: ^IO, endpoint: net.Endpoint, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion, err := _connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, socket, err)
	})
    if err != nil {
        callback(p, p2, {}, err)
        return completion
    }

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

connect3 :: proc(io: ^IO, endpoint: net.Endpoint, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, socket: net.TCP_Socket, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS  {
	completion, err := _connect(io, endpoint, nil, proc(completion: rawptr, socket: net.TCP_Socket, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, socket, err)
	})
    if err != nil {
        callback(p, p2, p3, {}, err)
        return completion
    }

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

_recv1 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, all: bool, p: $T, callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, received, udp_client, err)
	})

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

_recv2 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, all: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, received, udp_client, err)
	})

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

_recv3 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, all: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _recv(io, socket, buf, nil, proc(completion: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, received, udp_client, err)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

recv1 :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _recv1(io, socket, buf, false, p, callback)
}

recv2 :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _recv2(io, socket, buf, false, p, p2, callback)
}

recv3 :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _recv3(io, socket, buf, false, p, p2, p3, callback)
}

recv_all1 :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _recv1(io, socket, buf, true, p, callback)
}

recv_all2 :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _recv2(io, socket, buf, true, p, p2, callback)
}

recv_all3 :: #force_inline proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _recv3(io, socket, buf, true, p, p2, p3, callback)
}

_send1 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error), endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, sent, err)
	}, endpoint, all)

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

_send2 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error), endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
	}, endpoint, all)

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

_send3 :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error), endpoint: Maybe(net.Endpoint) = nil, all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _send(io, socket, buf, nil, proc(completion: rawptr, sent: int, err: net.Network_Error) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, sent, err)
	}, endpoint, all)

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

send_tcp1 :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _send1(io, socket, buf, p, callback)
}

send_tcp2 :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback)
}

send_tcp3 :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback)
}

send_udp1 :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _send1(io, socket, buf, p, callback, endpoint)
}

send_udp2 :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback, endpoint)
}

send_udp3 :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback, endpoint)
}

send_all_tcp1 :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _send1(io, socket, buf, p, callback, all = true)
}

send_all_tcp2 :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback, all = true)
}

send_all_tcp3 :: #force_inline proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback, all = true)
}

send_all_udp1 :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, callback: $C/proc(p: T, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _send1(io, socket, buf, p, callback, endpoint, all = true)
}

send_all_udp2 :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _send2(io, socket, buf, p, p2, callback, endpoint, all = true)
}

send_all_udp3 :: #force_inline proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, sent: int, err: net.Network_Error)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _send3(io, socket, buf, p, p2, p3, callback, endpoint, all = true)
}

/// Read Internal

_read1 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _read(io, fd, offset, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, read, err)
	}, all)

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

_read2 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _read(io, fd, offset, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, read, err)
	}, all)

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

_read3 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _read(io, fd, offset, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, read, err)
	}, all)

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

read1 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _read1(io, fd, nil, buf, p, callback)
}

read2 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _read2(io, fd, nil, buf, p, p2, callback)
}

read3 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _read3(io, fd, nil, buf, p, p2, p3, callback)
}

read_all1 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _read1(io, fd, nil, buf, p, callback, all = true)
}

read_all2 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _read2(io, fd, nil, buf, p, p2, callback, all = true)
}

read_all3 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _read3(io, fd, nil, buf, p, p2, p3, callback, all = true)
}

read_at1 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _read1(io, fd, offset, buf, p, callback)
}

read_at2 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _read2(io, fd, offset, buf, p, p2, callback)
}

read_at3 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _read3(io, fd, offset, buf, p, p2, p3, callback)
}

read_at_all1 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _read1(io, fd, offset, buf, p, callback, all = true)
}

read_at_all2 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _read2(io, fd, offset, buf, p, p2, callback, all = true)
}

read_at_all3 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, read: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _read3(io, fd, offset, buf, p, p2, p3, callback, all = true)
}

_write1 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _write(io, fd, offset, buf, nil, proc(completion: rawptr, written: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, written, err)
	}, all)

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

_write2 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _write(io, fd, offset, buf, nil, proc(completion: rawptr, written: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, written, err)
	}, all)

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

_write3 :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno), all := false) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _write(io, fd, offset, buf, nil, proc(completion: rawptr, written: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, written, err)
	}, all)

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

write1 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _write1(io, fd, nil, buf, p, callback)
}

write2 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _write2(io, fd, nil, buf, p, p2, callback)
}

write3 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _write3(io, fd, nil, buf, p, p2, p3, callback)
}

write_all1 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _write1(io, fd, nil, buf, p, callback, all = true)
}

write_all2 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _write2(io, fd, nil, buf, p, p2, callback, all = true)
}

write_all3 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _write3(io, fd, nil, buf, p, p2, p3, callback, all = true)
}

write_at1 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _write1(io, fd, offset, buf, p, callback)
}

write_at2 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _write2(io, fd, offset, buf, p, p2, callback)
}

write_at3 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _write3(io, fd, offset, buf, p, p2, p3, callback)
}

write_at_all1 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return _write1(io, fd, offset, buf, p, callback, all = true)
}

write_at_all2 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return _write2(io, fd, offset, buf, p, p2, callback, all = true)
}

write_at_all3 :: #force_inline proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return _write3(io, fd, offset, buf, p, p2, p3, callback, all = true)
}

poll1 :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, p: $T, callback: $C/proc(p: T, event: Poll_Event)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _poll(io, fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p, event)
	})

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

poll2 :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, event: Poll_Event)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _poll(io, fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2, event)
	})

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

poll3 :: proc(io: ^IO, fd: os.Handle, event: Poll_Event, multi: bool, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, event: Poll_Event)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _poll(io, fd, event, multi, nil, proc(completion: rawptr, event: Poll_Event) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, event)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}
