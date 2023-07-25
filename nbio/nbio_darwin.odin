//+private
package nbio

import "core:c"
import "core:os"
import "core:time"
import "core:mem"
import "core:net"

import "../kqueue"

Handle :: os.Handle

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

KQueue :: struct {
	fd:          os.Handle,
	io_inflight: int,
	timeouts:    [dynamic]^Completion,
	completed:   [dynamic]^Completion,
	io_pending:  [dynamic]^Completion,
	allocator:   mem.Allocator,
}

Completion :: struct {
	operation:     Operation,
	callback:      proc(kq: ^KQueue, c: ^Completion),
	user_callback: rawptr,
	user_data:     rawptr,
}

_init :: proc(
	io: ^IO,
	entries: u32 = DEFAULT_ENTRIES,
	flags: u32 = 0,
	allocator := context.allocator,
) -> (
	err: os.Errno,
) {
	kq := new(KQueue, allocator)
	defer if err != os.ERROR_NONE do free(kq, allocator)

	qerr: kqueue.Queue_Error
	kq.fd, qerr = kqueue.kqueue()
	if qerr != .None do return kq_err_to_os_err(qerr)

	kq.timeouts = make([dynamic]^Completion, allocator)
	kq.completed = make([dynamic]^Completion, allocator)
	kq.io_pending = make([dynamic]^Completion, allocator)
	kq.allocator = allocator

	io.impl_data = kq

	return
}

_destroy :: proc(io: ^IO) {
	kq := cast(^KQueue)io.impl_data
	for timeout in kq.timeouts do free(timeout, kq.allocator)
	for completed in kq.completed do free(completed, kq.allocator)
	for pending in kq.io_pending do free(pending, kq.allocator)
	delete(kq.timeouts)
	delete(kq.completed)
	delete(kq.io_pending)
	os.close(kq.fd)
	free(kq, kq.allocator)
}

// TODO: should this be the entries parameter?
MAX_EVENTS :: 256

_tick :: proc(io: ^IO) -> os.Errno {
	return flush(io, false)
}

flush :: proc(io: ^IO, wait_for_completions: bool) -> os.Errno {
	kq := cast(^KQueue)io.impl_data

	events: [MAX_EVENTS]kqueue.KEvent

	next_timeout := flush_timeouts(kq)
	change_events := flush_io(kq, events[:])

	if (change_events > 0 || len(kq.completed) == 0) {
		ts: kqueue.Time_Spec

		if (change_events == 0 && len(kq.completed) == 0) {
			if (wait_for_completions) {
				timeout := next_timeout.(i64) or_else panic("blocking forever")
				ts.nsec = timeout % NANOSECONDS_PER_SECOND
				ts.sec = c.long(timeout / NANOSECONDS_PER_SECOND)
			} else if (kq.io_inflight == 0) {
				return os.ERROR_NONE
			}
		}

		new_events, err := kqueue.kevent(kq.fd, events[:change_events], events[:], &ts)
		if err != .None do return ev_err_to_os_err(err)

		for _ in 0..<change_events {
			unordered_remove(&kq.io_pending, 0)
		}

		kq.io_inflight += change_events
		kq.io_inflight -= new_events

		// TODO(perf): don't do this and after the resize to 0, exec callbacks for these events.
		// This is an unnecessary append to then directly remove outside of this if.
		reserve(&kq.completed, new_events)
		for event in events[:new_events] {
			completion := cast(^Completion)event.udata
			append(&kq.completed, completion)
		}
	}

	for completed in &kq.completed {
		completed.callback(kq, completed)
	}
	resize(&kq.completed, 0)

	return os.ERROR_NONE
}

flush_io :: proc(kq: ^KQueue, events: []kqueue.KEvent) -> int {
	events := events
	for event, i in &events {
		if len(kq.io_pending) <= i do return i
		completion := kq.io_pending[i]

		switch op in completion.operation {
		case Op_Accept:
			event.ident = uintptr(op.socket)
			event.filter = kqueue.EVFILT_READ
		case Op_Connect:
			event.ident = uintptr(op.socket)
			event.filter = kqueue.EVFILT_WRITE
		case Op_Read:
			event.ident = uintptr(op.fd)
			event.filter = kqueue.EVFILT_READ
		case Op_Write:
			event.ident = uintptr(op.fd)
			event.filter = kqueue.EVFILT_WRITE
		case Op_Recv:
			event.ident = uintptr(op.socket)
			event.filter = kqueue.EVFILT_READ
		case Op_Send:
			event.ident = uintptr(op.socket)
			event.filter = kqueue.EVFILT_WRITE
		case:
			panic("invalid completion operation queued")
		}

		event.flags = kqueue.EV_ADD | kqueue.EV_ENABLE | kqueue.EV_ONESHOT
		event.udata = completion
	}

	return len(events)
}

flush_timeouts :: proc(kq: ^KQueue) -> (min_timeout: Maybe(i64)) {
	now := time.to_unix_nanoseconds(time.now())

	// PERF(laytan): probably to be optimized later.
	to_remove := make([dynamic]int, 0, len(kq.timeouts))
	defer {
		for i in to_remove {
			unordered_remove(&kq.timeouts, i)
		}
	}

	for completion, i in kq.timeouts {
		timeout, ok := completion.operation.(Op_Timeout)
		if !ok do panic("non-timeout operation found in the timeouts queue")

		expires := time.to_unix_nanoseconds(timeout.expires)
		if now >= expires {
			append(&to_remove, i)
			append(&kq.completed, completion)
			continue
		}

		timeout_ns := expires - now
		if min, has_min_timeout := min_timeout.(i64); has_min_timeout {
			if timeout_ns < min {
				min_timeout = timeout_ns
			}
		} else {
			min_timeout = timeout_ns
		}
	}

	return
}

Op_Accept :: distinct net.TCP_Socket

// TODO: maybe call this accept_tcp, or can we make it work with udp?
// can you even accept from udp sockets?
_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Accept(socket)

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Accept)

		client, source, err := net.accept_tcp(net.TCP_Socket(op))
		if err == net.Accept_Error.WouldBlock {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(On_Accept)completion.user_callback
		callback(completion.user_data, client, source, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Op_Close :: distinct Handle

// Wraps os.close using the kqueue.
_close :: proc(io: ^IO, fd: Handle, user: rawptr, callback: On_Close) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Close(fd)

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Close)
		ok := os.close(Handle(op))

		callback := cast(On_Close)completion.user_callback
		callback(completion.user_data, ok)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Op_Connect :: struct {
	socket: net.TCP_Socket,
	sockaddr: os.SOCKADDR_STORAGE_LH,
	initiated: bool,
}

// TODO: maybe call this dial?
_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	kq := cast(^KQueue)io.impl_data

	if endpoint.port == 0 {
		callback(user, {}, net.Dial_Error.Port_Required)
		return
	}

	family := net.family_from_endpoint(endpoint)
	sock, err := net.create_socket(family, .TCP)
	if err != nil {
		callback(user, {}, err)
		return
	}

	if err := prepare_socket(sock); err != nil {
		callback(user, {}, err)
		return
	}

	completion := new(Completion, kq.allocator)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Connect{
		socket = sock.(net.TCP_Socket),
		sockaddr = _endpoint_to_sockaddr(endpoint),
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := &completion.operation.(Op_Connect)
		defer op.initiated = true

		err: os.Errno
		if op.initiated {
			// We have already called os.connect, retrieve error number only.
			os.getsockopt(op.socket, os.SOL_SOCKET, os.SO_ERROR, &err, size_of(os.Errno))
		} else {
			err = os.connect(os.Socket(op.socket), (^os.SOCKADDR)(&op.sockaddr), i32(op.sockaddr.len))
			if err == os.EINPROGRESS {
				append(&kq.io_pending, completion)
				return
			}
		}

		callback := cast(On_Connect)completion.user_callback
		callback(completion.user_data, op.socket, net.Dial_Error(err))

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Op_Read :: struct {
	fd:     Handle,
	buf:    []byte,
}

_read :: proc(io: ^IO, fd: Handle, buf: []byte, user: rawptr, callback: On_Read) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Read{
		fd = fd,
		buf = buf,
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Read)

		read, err := os.read(op.fd, op.buf)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}


		callback := cast(On_Read)completion.user_callback
		callback(completion.user_data, read, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Op_Recv :: struct {
	socket: net.Any_Socket,
	buf: []byte,
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Recv{
		socket = socket,
		buf = buf,
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Recv)

		received: int
		err: net.Network_Error
		remote_endpoint: net.Endpoint
		switch sock in op.socket {
		case net.TCP_Socket:
			received, err = net.recv_tcp(sock, op.buf)

			// NOTE: Timeout is the name for EWOULDBLOCK in net package.
			if err == net.TCP_Recv_Error.Timeout {
				append(&kq.io_pending, completion)
				return
			}
		case net.UDP_Socket:
			received, remote_endpoint, err = net.recv_udp(sock, op.buf)

			// NOTE: Timeout is the name for EWOULDBLOCK in net package.
			if err == net.UDP_Recv_Error.Timeout {
				append(&kq.io_pending, completion)
				return
			}
		}

		callback := cast(On_Recv)completion.user_callback
		callback(completion.user_data, received, remote_endpoint, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

// Wraps os.send using the kqueue.
_send :: proc(io: ^IO, op: Op_Send, user_data: rawptr, callback: Send_Callback) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := &completion.operation.(Op_Send)

		sent, err := os.send(op.socket, op.buf, op.flags)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(Send_Callback)completion.user_callback
		callback(completion.user_data, sent, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

// Wraps os.write using the kqueue.
_write :: proc(io: ^IO, op: Op_Write, user_data: rawptr, callback: Write_Callback) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := &completion.operation.(Op_Write)

		read, err := os.write_at(op.fd, op.buf, op.offset)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(Write_Callback)completion.user_callback
		callback(completion.user_data, read, err)

		free(completion, kq.allocator)
	}

	append(&kq.completed, completion)
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user_data: rawptr, callback: Timeout_Callback) {
	kq := cast(^KQueue)io.impl_data

	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Timeout {
		expires = time.time_add(time.now(), dur),
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		callback := cast(Timeout_Callback)completion.user_callback
		callback(completion.user_data)

		free(completion, kq.allocator)
	}
	append(&kq.timeouts, completion)
}

@(private = "file")
kq_err_to_os_err :: proc(err: kqueue.Queue_Error) -> os.Errno {
	switch err {
	case .Out_Of_Memory:
		return os.ENOMEM
	case .Descriptor_Table_Full:
		return os.EMFILE
	case .File_Table_Full:
		return os.ENFILE
	case .Unknown:
		return os.EFAULT
	case .None:
		fallthrough
	case:
		return os.ERROR_NONE
	}
}

@(private = "file")
ev_err_to_os_err :: proc(err: kqueue.Event_Error) -> os.Errno {
	switch err {
	case .Access_Denied:
		return os.EACCES
	case .Invalid_Event:
		return os.EFAULT
	case .Invalid_Descriptor:
		return os.EBADF
	case .Signal:
		return os.EINTR
	case .Invalid_Timeout_Or_Filter:
		return os.EINVAL
	case .Event_Not_Found:
		return os.ENOENT
	case .Out_Of_Memory:
		return os.ENOMEM
	case .Process_Not_Found:
		return os.ESRCH
	case .Unknown:
		return os.EFAULT
	case .None:
		fallthrough
	case:
		return os.ERROR_NONE
	}
}

// Private proc in net package, verbatim copy.
_endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: os.SOCKADDR_STORAGE_LH) {
	switch a in ep.address {
	case IP4_Address:
		(^os.sockaddr_in)(&sockaddr)^ = os.sockaddr_in {
			sin_port = u16be(ep.port),
			sin_addr = transmute(os.in_addr) a,
			sin_family = u8(os.AF_INET),
			sin_len = size_of(os.sockaddr_in),
		}
		return
	case IP6_Address:
		(^os.sockaddr_in6)(&sockaddr)^ = os.sockaddr_in6 {
			sin6_port = u16be(ep.port),
			sin6_addr = transmute(os.in6_addr) a,
			sin6_family = u8(os.AF_INET6),
			sin6_len = size_of(os.sockaddr_in6),
		}
		return
	}
	unreachable()
}
