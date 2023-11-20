//+private
package nbio

import "core:container/queue"
import "core:mem"
import "core:net"
import "core:os"
import "core:runtime"
import "core:time"

import kqueue "_kqueue"

MAX_EVENTS :: 256

_IO :: struct {
	kq:              os.Handle,
	io_inflight:     int,
	completion_pool: Pool(Completion),
	timeouts:        [dynamic]^Completion,
	completed:       queue.Queue(^Completion),
	io_pending:      [dynamic]^Completion,
	allocator:       mem.Allocator,
}

_Completion :: struct {
	operation: Operation,
	ctx:       runtime.Context,
}

Op_Accept :: struct {
	callback: On_Accept,
	sock:     net.TCP_Socket,
}

Op_Close :: struct {
	callback: On_Close,
	handle:   os.Handle,
}

Op_Connect :: struct {
	callback:  On_Connect,
	socket:    net.TCP_Socket,
	sockaddr:  os.SOCKADDR_STORAGE_LH,
	initiated: bool,
}

Op_Recv :: struct {
	callback: On_Recv,
	socket:   net.Any_Socket,
	buf:      []byte,
	all:      bool,
	received: int,
	len:      int,
}

Op_Send :: struct {
	callback: On_Sent,
	socket:   net.Any_Socket,
	buf:      []byte,
	endpoint: Maybe(net.Endpoint),
	all:      bool,
	len:      int,
	sent:     int,
}

Op_Read :: struct {
	callback: On_Read,
	fd:       os.Handle,
	buf:      []byte,
	offset:	  int,
	all:   	  bool,
	read:  	  int,
	len:   	  int,
}

Op_Write :: struct {
	callback: On_Write,
	fd:       os.Handle,
	buf:      []byte,
	offset:   int,
	all:      bool,
	written:  int,
	len:      int,
}

Op_Timeout :: struct {
	callback:       On_Timeout,
	expires:        time.Time,
	completed_time: time.Time,
}

flush :: proc(io: ^IO) -> os.Errno {
	events: [MAX_EVENTS]kqueue.KEvent

	_ = flush_timeouts(io)
	change_events := flush_io(io, events[:])

	if (change_events > 0 || queue.len(io.completed) == 0) {
		if (change_events == 0 && queue.len(io.completed) == 0 && io.io_inflight == 0) {
			return os.ERROR_NONE
		}

		ts: kqueue.Time_Spec
		new_events, err := kqueue.kevent(io.kq, events[:change_events], events[:], &ts)
		if err != .None do return ev_err_to_os_err(err)

		// PERF: this is ordered and O(N), can this be made unordered?
		remove_range(&io.io_pending, 0, change_events)

		io.io_inflight += change_events
		io.io_inflight -= new_events

		if new_events > 0 {
			queue.reserve(&io.completed, new_events)
			for event in events[:new_events] {
				completion := cast(^Completion)event.udata
				queue.push_back(&io.completed, completion)
			}
		}
	}

	// Save length so we avoid an infinite loop when there is added to the queue in a callback.
	n := queue.len(io.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx

		switch &op in completed.operation {
		case Op_Accept:   do_accept (io, completed, &op)
		case Op_Close:    do_close  (io, completed, &op)
		case Op_Connect:  do_connect(io, completed, &op)
		case Op_Read:     do_read   (io, completed, &op)
		case Op_Recv:     do_recv   (io, completed, &op)
		case Op_Send:     do_send   (io, completed, &op)
		case Op_Write:    do_write  (io, completed, &op)
		case Op_Timeout:  do_timeout(io, completed, &op)
		case: unreachable()
		}
	}

	return os.ERROR_NONE
}

flush_io :: proc(io: ^IO, events: []kqueue.KEvent) -> int {
	events := events
	for event, i in &events {
		if len(io.io_pending) <= i do return i
		completion := io.io_pending[i]

		switch op in completion.operation {
		case Op_Accept:
			event.ident = uintptr(op.sock)
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
			event.ident = uintptr(os.Socket(net.any_socket_to_socket(op.socket)))
			event.filter = kqueue.EVFILT_READ
		case Op_Send:
			event.ident = uintptr(os.Socket(net.any_socket_to_socket(op.socket)))
			event.filter = kqueue.EVFILT_WRITE
		case Op_Timeout, Op_Close:
			panic("invalid completion operation queued")
		}

		event.flags = kqueue.EV_ADD | kqueue.EV_ENABLE | kqueue.EV_ONESHOT
		event.udata = completion
	}

	return len(events)
}

flush_timeouts :: proc(io: ^IO) -> (min_timeout: Maybe(i64)) {
	now: time.Time
	// PERF: is there a faster way to compare time? Or time since program start and compare that?
	if len(io.timeouts) > 0 do now = time.now()

	for i := len(io.timeouts) - 1; i >= 0; i -= 1 {
		completion := io.timeouts[i]

		timeout, ok := &completion.operation.(Op_Timeout)
		if !ok do panic("non-timeout operation found in the timeouts queue")

		unow := time.to_unix_nanoseconds(now)
		expires := time.to_unix_nanoseconds(timeout.expires)
		if unow >= expires {
			timeout.completed_time = now

			ordered_remove(&io.timeouts, i)
			queue.push_back(&io.completed, completion)
			continue
		}

		timeout_ns := expires - unow
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

do_accept :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	client, source, err := net.accept_tcp(op.sock)
	if err == net.Accept_Error.Would_Block {
		append(&io.io_pending, completion)
		return
	}

	if err == nil {
		err = _prepare_socket(client)
	}

	if err != nil {
		net.close(client)
		op.callback(completion.user_data, {}, {}, err)
	} else {
		op.callback(completion.user_data, client, source, nil)
	}

	pool_put(&io.completion_pool, completion)
}

do_close :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	ok := os.close(op.handle)

	op.callback(completion.user_data, ok)

	pool_put(&io.completion_pool, completion)
}

do_connect :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	defer op.initiated = true

	err: os.Errno
	if op.initiated {
		// We have already called os.connect, retrieve error number only.
		os.getsockopt(os.Socket(op.socket), os.SOL_SOCKET, os.SO_ERROR, &err, size_of(os.Errno))
	} else {
		err = os.connect(os.Socket(op.socket), (^os.SOCKADDR)(&op.sockaddr), i32(op.sockaddr.len))
		if err == os.EINPROGRESS {
			append(&io.io_pending, completion)
			return
		}
	}

	if err != os.ERROR_NONE {
		net.close(op.socket)
		op.callback(completion.user_data, {}, net.Dial_Error(err))
	} else {
		op.callback(completion.user_data, op.socket, nil)
	}

	pool_put(&io.completion_pool, completion)
}

do_read :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	read: int
	err: os.Errno
	//odinfmt:disable
	switch {
	case op.offset >= 0: read, err = os.read_at(op.fd, op.buf, i64(op.offset))
	case:                read, err = os.read(op.fd, op.buf)
	}
	//odinfmt:enable

	op.read += read

	if err != os.ERROR_NONE {
		if err == os.EWOULDBLOCK {
			append(&io.io_pending, completion)
			return
		}

		op.callback(completion.user_data, op.read, err)
		pool_put(&io.completion_pool, completion)
		return
	}

	if op.all && op.read < op.len {
		op.buf = op.buf[read:]

		if op.offset >= 0 {
			op.offset += read
		}

		do_read(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.read, os.ERROR_NONE)
	pool_put(&io.completion_pool, completion)
}

do_recv :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	received: int
	err: net.Network_Error
	remote_endpoint: Maybe(net.Endpoint)
	switch sock in op.socket {
	case net.TCP_Socket:
		received, err = net.recv_tcp(sock, op.buf)

		// NOTE: Timeout is the name for EWOULDBLOCK in net package.
		if err == net.TCP_Recv_Error.Timeout {
			append(&io.io_pending, completion)
			return
		}
	case net.UDP_Socket:
		received, remote_endpoint, err = net.recv_udp(sock, op.buf)

		// NOTE: Timeout is the name for EWOULDBLOCK in net package.
		if err == net.UDP_Recv_Error.Timeout {
			append(&io.io_pending, completion)
			return
		}
	}

	op.received += received

	if err != nil {
		op.callback(completion.user_data, op.received, remote_endpoint, err)
		pool_put(&io.completion_pool, completion)
		return
	}

	if op.all && op.received < op.len {
		op.buf = op.buf[received:]
		do_recv(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.received, remote_endpoint, err)
	pool_put(&io.completion_pool, completion)
}

do_send :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	sent:  u32
	errno: os.Errno
	err:   net.Network_Error

	switch sock in op.socket {
	case net.TCP_Socket:
		sent, errno = os.send(os.Socket(sock), op.buf, 0)
		err = net.TCP_Send_Error(errno)

	case net.UDP_Socket:
		toaddr := _endpoint_to_sockaddr(op.endpoint.(net.Endpoint))
		sent, errno = os.sendto(os.Socket(sock), op.buf, 0, cast(^os.SOCKADDR)&toaddr, i32(toaddr.len))
		err = net.UDP_Send_Error(errno)
	}

	op.sent += int(sent)

	if errno != os.ERROR_NONE {
		if errno == os.EWOULDBLOCK {
			append(&io.io_pending, completion)
			return
		}

		op.callback(completion.user_data, op.sent, err)
		pool_put(&io.completion_pool, completion)
		return
	}

	if op.all && op.sent < op.len {
		op.buf = op.buf[sent:]
		do_send(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.sent, nil)
	pool_put(&io.completion_pool, completion)
}

do_write :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	written: int
	err: os.Errno
	//odinfmt:disable
	switch {
	case op.offset >= 0: written, err = os.write_at(op.fd, op.buf, i64(op.offset))
	case:                written, err = os.write(op.fd, op.buf)
	}
	//odinfmt:enable

	op.written += written

	if err != os.ERROR_NONE {
		if err == os.EWOULDBLOCK {
			append(&io.io_pending, completion)
			return
		}

		op.callback(completion.user_data, op.written, err)
		pool_put(&io.completion_pool, completion)
		return
	}

	// The write did not write the whole buffer, need to write more.
	if op.all && op.written < op.len {
		op.buf = op.buf[written:]

		// Increase offset so we don't overwrite what we just wrote.
		if op.offset >= 0 {
			op.offset += written
		}

		do_write(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.written, os.ERROR_NONE)
	pool_put(&io.completion_pool, completion)
}

do_timeout :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	op.callback(completion.user_data, op.completed_time)
	pool_put(&io.completion_pool, completion)
}

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
	case net.IP4_Address:
		(^os.sockaddr_in)(&sockaddr)^ = os.sockaddr_in {
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(os.in_addr)a,
			sin_family = u8(os.AF_INET),
			sin_len    = size_of(os.sockaddr_in),
		}
		return
	case net.IP6_Address:
		(^os.sockaddr_in6)(&sockaddr)^ = os.sockaddr_in6 {
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(os.in6_addr)a,
			sin6_family = u8(os.AF_INET6),
			sin6_len    = size_of(os.sockaddr_in6),
		}
		return
	}
	unreachable()
}
