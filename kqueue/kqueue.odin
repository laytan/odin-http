//+build darwin
package kqueue

import "core:c"
import "core:os"
import "core:time"
import "core:mem"

KQueue :: struct {
	fd:          os.Handle,
	io_inflight: int,
	timeouts:    [dynamic]^Completion,
	completed:   [dynamic]^Completion,
	io_pending:  [dynamic]^Completion,
	allocator:   mem.Allocator,
}

init :: proc(kq: ^KQueue, allocator := context.allocator) -> (err: Queue_Error) {
	kq.fd = kqueue() or_return
	kq.timeouts = make([dynamic]^Completion, allocator)
	kq.completed = make([dynamic]^Completion, allocator)
	kq.io_pending = make([dynamic]^Completion, allocator)
	kq.allocator = allocator
	return
}

destroy :: proc(kq: ^KQueue) {
	for timeout in kq.timeouts do free(timeout, kq.allocator)
	for completed in kq.completed do free(completed, kq.allocator)
	for pending in kq.io_pending do free(pending, kq.allocator)
	delete(kq.timeouts)
	delete(kq.completed)
	delete(kq.io_pending)
	os.close(kq.fd)
}

@(private)
NANOSECONDS_PER_SECOND :: 1e+9
@(private)
MAX_EVENTS :: 256

flush :: proc(kq: ^KQueue, wait_for_completions: bool) -> Event_Error {
	events: [MAX_EVENTS]KEvent

	next_timeout := flush_timeouts(kq)
	change_events := flush_io(kq, events[:])

	if (change_events > 0 || len(kq.completed) == 0) {
		ts: Time_Spec

		if (change_events == 0 && len(kq.completed) == 0) {
			if (wait_for_completions) {
				timeout := next_timeout.(i64) or_else panic("blocking forever")
				ts.nsec = timeout % NANOSECONDS_PER_SECOND
				ts.sec = c.long(timeout / NANOSECONDS_PER_SECOND)
			} else if (kq.io_inflight == 0) {
				return .None
			}
		}

		new_events := kevent(kq.fd, events[:change_events], events[:], &ts) or_return

		for i := 0; i < change_events; i += 1 {
			unordered_remove(&kq.io_pending, 0)
		}

		kq.io_inflight += change_events
		kq.io_inflight -= new_events

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

	return .None
}

tick :: proc(kq: ^KQueue) -> Event_Error {
	return flush(kq, false)
}

@(private)
flush_io :: proc(kq: ^KQueue, events: []KEvent) -> int {
	events := events
	for event, i in &events {
		if len(kq.io_pending) <= i do return i
		completion := kq.io_pending[i]

		#partial switch op in completion.operation {
		case Op_Accept:
			event.ident = uintptr(op.socket)
			event.filter = EVFILT_READ
		case Op_Connect:
			event.ident = uintptr(op.socket)
			event.filter = EVFILT_WRITE
		case Op_Read:
			event.ident = uintptr(op.fd)
			event.filter = EVFILT_READ
		case Op_Write:
			event.ident = uintptr(op.fd)
			event.filter = EVFILT_WRITE
		case Op_Recv:
			event.ident = uintptr(op.socket)
			event.filter = EVFILT_READ
		case Op_Send:
			event.ident = uintptr(op.socket)
			event.filter = EVFILT_WRITE
		case:
			panic("invalid completion operation queued")
		}

		event.flags = EV_ADD | EV_ENABLE | EV_ONESHOT
		event.udata = completion
	}

	return len(events)
}

@(private)
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

@(private)
Completion :: struct {
	operation:     Operation,
	callback:      proc(k: ^KQueue, c: ^Completion),
	user_callback: rawptr,
	user_data:     rawptr,
}

Op_Accept :: struct {
	socket: os.Socket,
}

Op_Close :: struct {
	fd: os.Handle,
}

Op_Connect :: struct {
	socket:    os.Socket,
	addr:      ^os.SOCKADDR,
	len:       os.socklen_t,
	initiated: bool,
}

Op_Read :: struct {
	fd:     os.Handle,
	buf:    []byte,
	offset: i64,
}

Op_Recv :: struct {
	socket: os.Socket,
	buf:    []byte,
	flags:  int,
}

Op_Send :: struct {
	socket: os.Socket,
	buf:    []byte,
	flags:  int,
}

Op_Timeout :: struct {
	expires: time.Time,
}

Op_Write :: struct {
	fd:     os.Handle,
	buf:    []byte,
	offset: i64,
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

Accept_Callback :: proc(
	user_data: rawptr,
	sock: os.Socket,
	addr: os.SOCKADDR_STORAGE_LH,
	addr_len: c.int,
	err: os.Errno,
)

// Wraps os.accept using the kqueue.
accept :: proc(kq: ^KQueue, socket: os.Socket, user_data: rawptr, callback: Accept_Callback) {
	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Accept{socket}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Accept)

		sockaddr: os.SOCKADDR_STORAGE_LH
		sockaddrlen := c.int(size_of(sockaddr))

		sock, err := os.accept(op.socket, cast(^os.SOCKADDR)&sockaddr, &sockaddrlen)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(Accept_Callback)completion.user_callback
		callback(completion.user_data, sock, sockaddr, sockaddrlen, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Close_Callback :: proc(user_data: rawptr, ok: bool)

// Wraps os.close using the kqueue.
close :: proc(kq: ^KQueue, fd: os.Handle, user_data: rawptr, callback: Close_Callback) {
	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Close{fd}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Close)
		ok := os.close(op.fd)

		callback := cast(Close_Callback)completion.user_callback
		callback(completion.user_data, ok)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Connect_Callback :: proc(user_data: rawptr, sock: os.Socket, err: os.Errno)

// Wraps os.connect using the kqueue.
connect :: proc(kq: ^KQueue, op: Op_Connect, user_data: rawptr, callback: Connect_Callback) {
	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := &completion.operation.(Op_Connect)
		defer op.initiated = true

		err: os.Errno
		if op.initiated {
			os.getsockopt(op.socket, os.SOL_SOCKET, os.SO_ERROR, &err, size_of(os.Errno))
		} else {
			err = os.connect(op.socket, op.addr, op.len)
			if err == os.EINPROGRESS {
				append(&kq.io_pending, completion)
				return
			}
		}

		callback := cast(Connect_Callback)completion.user_callback
		callback(completion.user_data, op.socket, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Read_Callback :: proc(user_data: rawptr, read: int, err: os.Errno)

// Wraps os.read_at using the kqueue.
read :: proc(kq: ^KQueue, op: Op_Read, user_data: rawptr, callback: Read_Callback) {
	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Read)

		read, err := os.read_at(op.fd, op.buf, op.offset)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}


		callback := cast(Read_Callback)completion.user_callback
		callback(completion.user_data, read, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Recv_Callback :: proc(user_data: rawptr, buf: []byte, received: u32, err: os.Errno)

// Wraps os.recv using the kqueue.
recv :: proc(kq: ^KQueue, op: Op_Recv, user_data: rawptr, callback: Recv_Callback) {
	completion := new(Completion, kq.allocator)

	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Recv)

		received, err := os.recv(op.socket, op.buf, op.flags)
		if err == os.EWOULDBLOCK {
			append(&kq.io_pending, completion)
			return
		}

		callback := cast(Recv_Callback)completion.user_callback
		callback(completion.user_data, op.buf, received, err)

		free(completion, kq.allocator)
	}
	append(&kq.completed, completion)
}

Send_Callback :: proc(user_data: rawptr, sent: u32, err: os.Errno)

// Wraps os.send using the kqueue.
send :: proc(kq: ^KQueue, op: Op_Send, user_data: rawptr, callback: Send_Callback) {
	completion := new(Completion, kq.allocator)

	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Send)

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

Write_Callback :: proc(user_data: rawptr, written: int, err: os.Errno)

// Wraps os.write using the kqueue.
write :: proc(kq: ^KQueue, op: Op_Write, user_data: rawptr, callback: Write_Callback) {
	completion := new(Completion, kq.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		op := completion.operation.(Op_Write)

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

Timeout_Callback :: proc(user_data: rawptr)

// Runs the callback after the timeout, using the kqueue.
timeout :: proc(kq: ^KQueue, dur: time.Duration, user_data: rawptr, callback: Timeout_Callback) {
	completion := new(Completion, kq.allocator)

	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Timeout {
		expires = time.time_add(time.now(), dur),
	}

	completion.callback = proc(kq: ^KQueue, completion: ^Completion) {
		callback := cast(Timeout_Callback)completion.user_callback
		callback(completion.user_data)

		free(completion)
	}
	append(&kq.timeouts, completion)
}

Queue_Error :: enum {
	None,
	Out_Of_Memory,
	Descriptor_Table_Full,
	File_Table_Full,
	Unknown,
}

kqueue :: proc() -> (kq: os.Handle, err: Queue_Error) {
	kq = os.Handle(_kqueue())
	if kq == -1 {
		switch os.Errno(os.get_last_error()) {
		case os.ENOMEM:
			err = .Out_Of_Memory
		case os.EMFILE:
			err = .Descriptor_Table_Full
		case os.ENFILE:
			err = .File_Table_Full
		case:
			err = .Unknown
		}
	}
	return
}

Event_Error :: enum {
	None,
	Access_Denied,
	Invalid_Event,
	Invalid_Descriptor,
	Signal,
	Invalid_Timeout_Or_Filter,
	Event_Not_Found,
	Out_Of_Memory,
	Process_Not_Found,
	Unknown,
}

kevent :: proc(
	kq: os.Handle,
	change_list: []KEvent,
	event_list: []KEvent,
	timeout: ^Time_Spec,
) -> (
	n_events: int,
	err: Event_Error,
) {
	n_events = int(
		_kevent(
			c.int(kq),
			raw_data(change_list),
			c.int(len(change_list)),
			raw_data(event_list),
			c.int(len(event_list)),
			timeout,
		),
	)
	if n_events == -1 {
		switch os.Errno(os.get_last_error()) {
		case os.EACCES:
			err = .Access_Denied
		case os.EFAULT:
			err = .Invalid_Event
		case os.EBADF:
			err = .Invalid_Descriptor
		case os.EINTR:
			err = .Signal
		case os.EINVAL:
			err = .Invalid_Timeout_Or_Filter
		case os.ENOENT:
			err = .Event_Not_Found
		case os.ENOMEM:
			err = .Out_Of_Memory
		case os.ESRCH:
			err = .Process_Not_Found
		case:
			err = .Unknown
		}
	}
	return
}

KEvent :: struct {
	ident:  c.uintptr_t,
	filter: c.int16_t,
	flags:  c.uint16_t,
	fflags: c.uint32_t,
	data:   c.intptr_t,
	udata:  rawptr,
}

Time_Spec :: struct {
	sec:  c.long,
	nsec: c.long,
}

EV_ADD :: 0x0001 /* add event to kq (implies enable) */
EV_DELETE :: 0x0002 /* delete event from kq */
EV_ENABLE :: 0x0004 /* enable event */
EV_DISABLE :: 0x0008 /* disable event (not reported) */
EV_ONESHOT :: 0x0010 /* only report one occurrence */
EV_CLEAR :: 0x0020 /* clear event state after reporting */
EV_RECEIPT :: 0x0040 /* force immediate event output */
EV_DISPATCH :: 0x0080 /* disable event after reporting */
EV_UDATA_SPECIFIC :: 0x0100 /* unique kevent per udata value */
EV_FANISHED :: 0x0200 /* report that source has vanished  */
EV_SYSFLAGS :: 0xF000 /* reserved by system */
EV_FLAG0 :: 0x1000 /* filter-specific flag */
EV_FLAG1 :: 0x2000 /* filter-specific flag */
EV_ERROR :: 0x4000 /* error, data contains errno */
EV_EOF :: 0x8000 /* EOF detected */
EV_DISPATCH2 :: (EV_DISPATCH | EV_UDATA_SPECIFIC)

EVFILT_READ :: -1
EVFILT_WRITE :: -2
EVFILT_AIO :: -3
EVFILT_VNODE :: -4
EVFILT_PROC :: -5
EVFILT_SIGNAL :: -6
EVFILT_TIMER :: -7
EVFILT_MACHPORT :: -8
EVFILT_FS :: -9
EVFILT_USER :: -10
EVFILT_VM :: -12
EVFILT_EXCEPT :: -15

@(default_calling_convention = "c")
foreign _ {
	@(link_name = "kqueue")
	_kqueue :: proc() -> c.int ---
	@(link_name = "kevent")
	_kevent :: proc(kq: c.int, change_list: [^]KEvent, n_changes: c.int, event_list: [^]KEvent, n_events: c.int, timeout: ^Time_Spec) -> c.int ---
}
