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

import io_uring "_io_uring"

NANOSECONDS_PER_SECOND :: 1e+9

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

_Completion :: struct {
	result:    i32,
	operation: Operation,
	ctx:       runtime.Context,
}

Op_Accept :: struct {
	callback:    On_Accept,
	socket:      net.TCP_Socket,
	sockaddr:    os.SOCKADDR_STORAGE_LH,
	sockaddrlen: c.int,
}

Op_Close :: struct {
	callback: On_Close,
	fd:       os.Handle,
}

Op_Connect :: struct {
	callback: On_Connect,
	socket:   net.TCP_Socket,
	sockaddr: os.SOCKADDR_STORAGE_LH,
}

Op_Read :: struct {
	callback: On_Read,
	fd:       os.Handle,
	buf:      []byte,
	offset:   int,
	all:      bool,
	read:     int,
	len:      int,
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

Op_Send :: struct {
	callback: On_Sent,
	socket:   net.Any_Socket,
	buf:      []byte,
	len:      int,
	sent:     int,
	all:      bool,
}

Op_Recv :: struct {
	callback: On_Recv,
	socket:   net.Any_Socket,
	buf:      []byte,
	all:      bool,
	received: int,
	len:      int,
}

Op_Timeout :: struct {
	callback: On_Timeout,
	expires:  unix.timespec,
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
		switch &op in unqueued.operation {
		case Op_Accept:  accept_enqueue (io, unqueued, &op)
		case Op_Close:   close_enqueue  (io, unqueued, &op)
		case Op_Connect: connect_enqueue(io, unqueued, &op)
		case Op_Read:    read_enqueue   (io, unqueued, &op)
		case Op_Recv:    recv_enqueue   (io, unqueued, &op)
		case Op_Send:    send_enqueue   (io, unqueued, &op)
		case Op_Write:   write_enqueue  (io, unqueued, &op)
		case Op_Timeout: timeout_enqueue(io, unqueued, &op)
		}
	}

	n = queue.len(io.completed)
	for _ in 0 ..< n {
		completed := queue.pop_front(&io.completed)
		context = completed.ctx

		switch &op in completed.operation {
		case Op_Accept:   accept_callback (io, completed, &op)
		case Op_Close:    close_callback  (io, completed, &op)
		case Op_Connect:  connect_callback(io, completed, &op)
		case Op_Read:     read_callback   (io, completed, &op)
		case Op_Recv:     recv_callback   (io, completed, &op)
		case Op_Send:     send_callback   (io, completed, &op)
		case Op_Write:    write_callback  (io, completed, &op)
		case Op_Timeout:  timeout_callback(io, completed, &op)
		case: unreachable()
		}
	}
	// odinfmt: enable

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

accept_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
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

accept_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Accept) {
	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		switch errno {
		case os.EINTR, os.EWOULDBLOCK:
			accept_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, 0, {}, net.Accept_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	client := net.TCP_Socket(completion.result)
	err    := _prepare_socket(client)
	source := sockaddr_storage_to_endpoint(&op.sockaddr)

	op.callback(completion.user_data, client, source, err)
	pool_put(&io.completion_pool, completion)
}

close_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	_, err := io_uring.close(&io.ring, u64(uintptr(completion)), op.fd)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

close_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Close) {
	errno := os.Errno(-completion.result)

	// In particular close() should not be retried after an EINTR
	// since this may cause a reused descriptor from another thread to be closed.
	op.callback(completion.user_data, errno == os.ERROR_NONE || errno == os.EINTR)
	pool_put(&io.completion_pool, completion)
}

connect_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
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

connect_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Connect) {
	errno := os.Errno(-completion.result)
	switch errno {
	case os.EINTR, os.EWOULDBLOCK:
		connect_enqueue(io, completion, op)
		return
	case os.ERROR_NONE:
		op.callback(completion.user_data, op.socket, nil)
	case:
		net.close(op.socket)
		op.callback(completion.user_data, {}, net.Dial_Error(errno))
	}
	pool_put(&io.completion_pool, completion)
}

read_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	// Max tells linux to use the file cursor as the offset.
	offset := max(u64) if op.offset < 0 else u64(op.offset)

	_, err := io_uring.read(&io.ring, u64(uintptr(completion)), op.fd, op.buf, offset)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

read_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Read) {
	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		switch errno {
		case os.EINTR, os.EWOULDBLOCK:
			read_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, op.read, errno)
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.read += int(completion.result)

	if op.all && op.read < op.len {
		op.buf = op.buf[completion.result:]
		read_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.read, os.ERROR_NONE)
	pool_put(&io.completion_pool, completion)
}

recv_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
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

recv_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Recv) {
	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		switch errno {
		case os.EINTR, os.EWOULDBLOCK:
			recv_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, op.received, {}, net.TCP_Recv_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.received += int(completion.result)

	if op.all && op.received < op.len {
		op.buf = op.buf[completion.result:]
		recv_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.received, {}, nil)
	pool_put(&io.completion_pool, completion)
}

send_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
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

send_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Send) {
	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		switch errno {
		case os.EINTR, os.EWOULDBLOCK:
			send_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, op.sent, net.TCP_Send_Error(errno))
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.sent += int(completion.result)

	if op.all && op.sent < op.len {
		op.buf = op.buf[completion.result:]
		send_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.sent, nil)
	pool_put(&io.completion_pool, completion)
}

write_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	// Max tells linux to use the file cursor as the offset.
	offset := max(u64) if op.offset < 0 else u64(op.offset)

	_, err := io_uring.write(&io.ring, u64(uintptr(completion)), op.fd, op.buf, offset)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

write_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Write) {
	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		switch errno {
		case os.EINTR, os.EWOULDBLOCK:
			write_enqueue(io, completion, op)
		case:
			op.callback(completion.user_data, op.written, errno)
			pool_put(&io.completion_pool, completion)
		}
		return
	}

	op.written += int(completion.result)

	if op.all && op.written < op.len {
		op.buf = op.buf[completion.result:]

		if op.offset >= 0 {
			op.offset += int(completion.result)
		}

		write_enqueue(io, completion, op)
		return
	}

	op.callback(completion.user_data, op.written, os.ERROR_NONE)
	pool_put(&io.completion_pool, completion)
}

timeout_enqueue :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	_, err := io_uring.timeout(&io.ring, u64(uintptr(completion)), &op.expires, 0, 0)
	if err == .Submission_Queue_Full {
		queue.push_back(&io.unqueued, completion)
		return
	}

	io.ios_queued += 1
}

timeout_callback :: proc(io: ^IO, completion: ^Completion, op: ^Op_Timeout) {
	errno := os.Errno(-completion.result)
	switch errno {
	case os.EINTR, os.EWOULDBLOCK:
		timeout_enqueue(io, completion, op)
	case:
		// TODO: we are swallowing the returned error here.
		fmt.assertf(errno == os.ERROR_NONE || errno == os.ETIME, "timeout error: %v", errno)

		op.callback(completion.user_data, nil)
		pool_put(&io.completion_pool, completion)
	}
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
			sin_family = u16(os.AF_INET),
			sin_port   = u16be(ep.port),
			sin_addr   = transmute(os.in_addr)a,
		}
		return
	case net.IP6_Address:
		(^os.sockaddr_in6)(&sockaddr)^ = os.sockaddr_in6 {
			sin6_family = u16(os.AF_INET6),
			sin6_port   = u16be(ep.port),
			sin6_addr   = transmute(os.in6_addr)a,
		}
		return
	}
	unreachable()
}
