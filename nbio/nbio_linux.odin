//+private
package nbio

import "core:c"
import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:runtime"
import "core:sys/unix"
import "core:time"

import io_uring "_io_uring"

_IO :: struct {
	ring:            io_uring.IO_Uring,
	completion_pool: Pool(Completion),
	// Ready to be submitted to kernel.
	unqueued:        queue.Queue(^Completion),
	// Ready to run callbacks.
	completed:       queue.Queue(^Completion),
	ios_queued:      u64,
	ios_in_kernel:   u64,
	allocator:       mem.Allocator,
}

Completion :: struct {
	result:        i32,
	operation:     Operation,
	callback:      proc(io: ^IO, c: ^Completion),
	ctx:           runtime.Context,
	user_callback: rawptr,
	user_data:     rawptr,
}

_init :: proc(io: ^IO, alloc := context.allocator) -> (err: os.Errno) {
	flags:   u32 = 0
	entries: u32 = 32

	io.allocator = alloc

	pool_init(&io.completion_pool, allocator = alloc)

	params: io_uring.io_uring_params

	// Make read, write etc. increment and use the file cursor.
	params.features |= io_uring.IORING_FEAT_RW_CUR_POS

	ring, rerr := io_uring.io_uring_make(&params, entries, flags)
	#partial switch rerr {
	case .None:
		io.ring = ring
		queue.init(&io.unqueued, allocator = alloc)
		queue.init(&io.completed, allocator = alloc)
	case:
		err = ring_err_to_os_err(rerr)
	}

	return
}

_destroy :: proc(io: ^IO) {
	queue.destroy(&io.unqueued)
	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	io_uring.io_uring_destroy(&io.ring)
}

_tick :: proc(io: ^IO) -> os.Errno {
	timeouts: uint = 0
	etime := false

	err := flush(io, 0, &timeouts, &etime)
	if err != os.ERROR_NONE do return err

	assert(etime == false)

	queued := io.ring.sq.sqe_tail - io.ring.sq.sqe_head
	if queued > 0 {
		err = flush_submissions(io, 0, &timeouts, &etime)
		if err != os.ERROR_NONE do return err
		assert(etime == false)
	}

	return os.ERROR_NONE
}

flush :: proc(io: ^IO, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> os.Errno {
	err := flush_submissions(io, wait_nr, timeouts, etime)
	if err != os.ERROR_NONE do return err

	err = flush_completions(io, 0, timeouts, etime)
	if err != os.ERROR_NONE do return err

	// Store length at this time, so we don't infinite loop if any of the enqueue
	// procs below then add to the queue again.
	n := queue.len(io.unqueued)

	// odinfmt: disable
	for _ in 0..<n {
		unqueued := queue.pop_front(&io.unqueued)
		switch op in unqueued.operation {
		case Op_Accept:  accept_enqueue (io, unqueued)
		case Op_Close:   close_enqueue  (io, unqueued)
		case Op_Connect: connect_enqueue(io, unqueued)
		case Op_Read:    read_enqueue   (io, unqueued)
		case Op_Recv:    recv_enqueue   (io, unqueued)
		case Op_Send:    send_enqueue   (io, unqueued)
		case Op_Write:   write_enqueue  (io, unqueued)
		case Op_Timeout: timeout_enqueue(io, unqueued)
		}
	}
	// odinfmt: enable


	n = queue.len(io.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx
		completed.callback(io, completed)
	}

	return os.ERROR_NONE
}

flush_completions :: proc(io: ^IO, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> os.Errno {
	cqes: [256]io_uring.io_uring_cqe
	wait_remaining := wait_nr
	for {
		completed, err := io_uring.copy_cqes(&io.ring, cqes[:], wait_remaining)
		if err != .None do return ring_err_to_os_err(err)

		wait_remaining = max(0, wait_remaining - completed)

		if completed > 0 {
			queue.reserve(&io.completed, int(completed))
			for cqe in cqes[:completed] {
				io.ios_in_kernel -= 1

				if cqe.user_data == 0 {
					timeouts^ -= 1

					if (-cqe.res == i32(os.ETIME)) {
						etime^ = true
					}
					continue
				}

				completion := cast(^Completion)uintptr(cqe.user_data)
				completion.result = cqe.res

				queue.push_back(&io.completed, completion)
			}
		}

		if completed < len(cqes) do break
	}

	return os.ERROR_NONE
}

flush_submissions :: proc(io: ^IO, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> os.Errno {
	for {
		submitted, err := io_uring.submit(&io.ring, wait_nr)
		#partial switch err {
		case .None:
			break
		case .Signal_Interrupt:
			continue
		case .Completion_Queue_Overcommitted, .System_Resources:
			ferr := flush_completions(io, 1, timeouts, etime)
			if ferr != os.ERROR_NONE do return ferr
			continue
		case:
			return ring_err_to_os_err(err)
		}

		io.ios_queued -= u64(submitted)
		io.ios_in_kernel += u64(submitted)
		break
	}

	return os.ERROR_NONE
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	errno := os.listen(os.Socket(socket), backlog)
	return net.Listen_Error(errno)
}

Op_Accept :: struct {
	socket:      net.TCP_Socket,
	sockaddr:    os.SOCKADDR_STORAGE_LH,
	sockaddrlen: c.int,
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Accept {
		socket      = socket,
		sockaddrlen = c.int(size_of(os.SOCKADDR_STORAGE_LH)),
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		op := completion.operation.(Op_Accept)
		callback := cast(On_Accept)completion.user_callback

		if completion.result < 0 {
			errno := os.Errno(-completion.result)
			if errno == os.EINTR {
				accept_enqueue(io, completion)
				return
			}

			callback(completion.user_data, 0, {}, net.Accept_Error(errno))
			pool_put(&io.completion_pool, completion)
			return
		}

		client := net.TCP_Socket(completion.result)
		err := _prepare_socket(client)
		source := sockaddr_storage_to_endpoint(&op.sockaddr)

		callback(completion.user_data, client, source, err)
		pool_put(&io.completion_pool, completion)
	}

	accept_enqueue(io, completion)
}

accept_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := &completion.operation.(Op_Accept)

	_, err := io_uring.accept(
		&io.ring,
		u64(uintptr(completion)),
		os.Socket(op.socket),
		cast(^os.SOCKADDR)&op.sockaddr,
		&op.sockaddrlen,
	)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

Op_Close :: distinct os.Handle

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)



	//odinfmt:disable
	switch h in fd {
	case net.TCP_Socket: completion.operation = Op_Close(h)
	case net.UDP_Socket: completion.operation = Op_Close(h)
	case os.Handle:      completion.operation = Op_Close(h)
	} //odinfmt:enable

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		callback := cast(On_Close)completion.user_callback

		errno := os.Errno(-completion.result)

		// In particular close() should not be retried after an EINTR
		// since this may cause a reused descriptor from another thread to be closed.
		callback(completion.user_data, errno == os.ERROR_NONE || errno == os.EINTR)
		pool_put(&io.completion_pool, completion)
	}

	close_enqueue(io, completion)
}

close_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := completion.operation.(Op_Close)

	_, err := io_uring.close(&io.ring, u64(uintptr(completion)), os.Handle(op))
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

Op_Connect :: struct {
	socket:   net.TCP_Socket,
	sockaddr: os.SOCKADDR_STORAGE_LH,
}

_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
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

	if err := _prepare_socket(sock); err != nil {
		net.close(sock)
		callback(user, {}, err)
		return
	}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Connect {
		socket   = sock.(net.TCP_Socket),
		sockaddr = endpoint_to_sockaddr(endpoint),
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		op := &completion.operation.(Op_Connect)
		callback := cast(On_Connect)completion.user_callback

		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			connect_enqueue(io, completion)
			return
		}

		if errno != os.ERROR_NONE {
			net.close(op.socket)
			callback(completion.user_data, {}, net.Dial_Error(errno))
		} else {
			callback(completion.user_data, op.socket, nil)
		}

		pool_put(&io.completion_pool, completion)
	}

	connect_enqueue(io, completion)
}

connect_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := completion.operation.(Op_Connect)

	_, err := io_uring.connect(
		&io.ring,
		u64(uintptr(completion)),
		os.Socket(op.socket),
		cast(^os.SOCKADDR)&op.sockaddr,
		size_of(op.sockaddr),
	)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

Op_Read :: struct {
	fd:     os.Handle,
	buf:    []byte,
	offset: Maybe(int),
}

_read :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, user: rawptr, callback: On_Read) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Read {
		fd     = fd,
		buf    = buf,
		offset = offset,
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		callback := cast(On_Read)completion.user_callback

		if completion.result < 0 {
			errno := os.Errno(-completion.result)
			if errno == os.EINTR {
				connect_enqueue(io, completion)
				return
			}

			callback(completion.user_data, 0, errno)
			pool_put(&io.completion_pool, completion)
			return
		}

		callback(completion.user_data, int(completion.result), os.ERROR_NONE)
		pool_put(&io.completion_pool, completion)
	}

	read_enqueue(io, completion)
}

read_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := completion.operation.(Op_Read)

	offset: u64 = max(u64) // Max tells linux to use the file cursor as the offset.
	if off, ok := op.offset.?; ok {
		offset = u64(off)
	}

	_, err := io_uring.read(&io.ring, u64(uintptr(completion)), op.fd, op.buf, offset)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

Op_Recv :: struct {
	socket: net.Any_Socket,
	buf:    []byte,
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Recv {
		socket = socket,
		buf    = buf,
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		callback := cast(On_Recv)completion.user_callback

		if completion.result < 0 {
			errno := os.Errno(-completion.result)
			if errno == os.EINTR {
				recv_enqueue(io, completion)
				return
			}

			callback(completion.user_data, 0, {}, net.TCP_Recv_Error(errno))
			pool_put(&io.completion_pool, completion)
			return
		}

		callback(completion.user_data, int(completion.result), {}, nil)
		pool_put(&io.completion_pool, completion)
	}

	recv_enqueue(io, completion)
}

recv_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := completion.operation.(Op_Recv)

	tcpsock, ok := op.socket.(net.TCP_Socket)
	if !ok {
		// TODO: figure out and implement.
		unimplemented("UDP recv is unimplemented for linux nbio")
	}

	_, err := io_uring.recv(&io.ring, u64(uintptr(completion)), os.Socket(tcpsock), op.buf, 0)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}
	// TODO: handle other errors, also in other enqueue procs.

	io.ios_queued += 1
}

Op_Send :: struct {
	socket: net.Any_Socket,
	buf:    []byte,
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	_: Maybe(net.Endpoint) = nil,
) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Send {
		socket = socket,
		buf    = buf,
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		callback := cast(On_Sent)completion.user_callback

		if completion.result < 0 {
			errno := os.Errno(-completion.result)
			if errno == os.EINTR {
				send_enqueue(io, completion)
				return
			}

			callback(completion.user_data, 0, net.TCP_Send_Error(errno))
			pool_put(&io.completion_pool, completion)
			return
		}

		callback(completion.user_data, int(completion.result), nil)
		pool_put(&io.completion_pool, completion)
	}

	send_enqueue(io, completion)
}

send_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := &completion.operation.(Op_Send)

	tcpsock, ok := op.socket.(net.TCP_Socket)
	if !ok {
		// TODO: figure out and implement.
		unimplemented("UDP send is unimplemented for linux nbio")
	}

	_, err := io_uring.send(&io.ring, u64(uintptr(completion)), os.Socket(tcpsock), op.buf, 0)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

Op_Write :: struct {
	fd:     os.Handle,
	buf:    []byte,
	offset: Maybe(int),
}

_write :: proc(io: ^IO, fd: os.Handle, offset: Maybe(int), buf: []byte, user: rawptr, callback: On_Write) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Write {
		fd     = fd,
		buf    = buf,
		offset = offset,
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		callback := cast(On_Write)completion.user_callback

		if completion.result < 0 {
			errno := os.Errno(-completion.result)
			if errno == os.EINTR {
				write_enqueue(io, completion)
				return
			}

			callback(completion.user_data, 0, errno)
			pool_put(&io.completion_pool, completion)
			return
		}

		callback(completion.user_data, int(completion.result), os.ERROR_NONE)
		pool_put(&io.completion_pool, completion)
	}

	write_enqueue(io, completion)
}

write_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := &completion.operation.(Op_Write)

	offset: u64 = max(u64) // Max tells linux to use the file cursor as the offset.
	if off, ok := op.offset.?; ok {
		offset = u64(off)
	}

	_, err := io_uring.write(&io.ring, u64(uintptr(completion)), op.fd, op.buf, offset)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

Op_Timeout :: struct {
	expires: unix.timespec,
}

@(private="file")
NANOSECONDS_PER_SECOND :: 1e+9

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = rawptr(callback)

	nsec := time.duration_nanoseconds(dur)
	completion.operation = Op_Timeout {
		expires = unix.timespec{
			tv_sec = nsec / NANOSECONDS_PER_SECOND,
			tv_nsec = nsec % NANOSECONDS_PER_SECOND,
		},
	}

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		callback := cast(On_Timeout)completion.user_callback

		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			timeout_enqueue(io, completion)
			return
		}

		// TODO: we are swallowing the returned error here.
		fmt.assertf(errno == os.ERROR_NONE || errno == os.ETIME, "timeout error: %v", errno)

		callback(completion.user_data, nil)
		pool_put(&io.completion_pool, completion)
	}

	timeout_enqueue(io, completion)
}

timeout_enqueue :: proc(io: ^IO, completion: ^Completion) {
	op := &completion.operation.(Op_Timeout)

	_, err := io_uring.timeout(&io.ring, u64(uintptr(completion)), &op.expires, 0, io_uring.IORING_TIMEOUT_ABS)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

ring_err_to_os_err :: proc(err: io_uring.IO_Uring_Error) -> os.Errno {
	switch err {
	case .None:
		return os.ERROR_NONE
	case .Params_Outside_Accessible_Address_Space, .Buffer_Invalid, .File_Descriptor_Invalid, .Submission_Queue_Entry_Invalid, .Ring_Shutting_Down:
		return os.EFAULT
	case .Arguments_Invalid, .Entries_Zero, .Entries_Too_Large, .Entries_Not_Power_Of_Two, .Opcode_Not_Supported:
		return os.EINVAL
	case .Process_Fd_Quota_Exceeded:
		return os.EMFILE
	case .System_Fd_Quota_Exceeded:
		return os.ENFILE
	case .System_Resources, .Completion_Queue_Overcommitted:
		return os.ENOMEM
	case .Permission_Denied:
		return os.EPERM
	case .System_Outdated:
		return os.ENOSYS
	case .Submission_Queue_Full:
		return os.EOVERFLOW
	case .Signal_Interrupt:
		return os.EINTR
	case .Unexpected:
		fallthrough
	case:
		return -1
	}
}

// verbatim copy of net._sockaddr_storage_to_endpoint.
sockaddr_storage_to_endpoint :: proc(native_addr: ^os.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
	switch native_addr.ss_family {
	case u16(os.AF_INET):
		addr := cast(^os.sockaddr_in)native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte)addr.sin_addr),
			port    = port,
		}
	case u16(os.AF_INET6):
		addr := cast(^os.sockaddr_in6)native_addr
		port := int(addr.sin6_port)
		ep = net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be)addr.sin6_addr),
			port    = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
}

// verbatim copy of net._endpoint_to_sockaddr.
endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: os.SOCKADDR_STORAGE_LH) {
	switch a in ep.address {
	case net.IP4_Address:
		(^os.sockaddr_in)(&sockaddr)^ = os.sockaddr_in {
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(os.in_addr)a,
			sin_family = u16(os.AF_INET),
		}
		return
	case net.IP6_Address:
		(^os.sockaddr_in6)(&sockaddr)^ = os.sockaddr_in6 {
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(os.in6_addr)a,
			sin6_family = u16(os.AF_INET6),
		}
		return
	}
	unreachable()
}
