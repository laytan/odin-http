//+private
package nbio

import "core:os"
import "core:time"
import "core:mem"
import "core:container/queue"
import "core:net"

import "../io_uring"

Handle :: os.Handle

Linux :: struct {
	ring:          io_uring.IO_Uring,

	// Ready to be submitted to kernel.
	unqueued:      queue.Queue(^Completion),
	// Ready to run callbacks.
	completed:     queue.Queue(^Completion),
	ios_queued:    u64,
	ios_in_kernel: u64,
	allocator:     mem.Allocator,
}

Completion :: struct {
	result:        i32,
	operation:     Operation,
	callback:      proc(lx: ^Linux, c: ^Completion),
	user_callback: rawptr,
	user_data:     rawptr,
}

// TODO: does not make sense to take flags here?
_init :: proc(io: ^IO, entries: u32 = DEFAULT_ENTRIES, flags: u32 = 0, alloc := context.allocator) -> (err: os.Errno) {
	lx := new(Linux, alloc)
	io.impl_data = lx

	lx.allocator = alloc

	params: io_uring.io_uring_params
	ring, rerr := io_uring.io_uring_make(&params, entries, flags)
	#partial switch rerr {
	case .None:
		lx.ring = ring
		queue.init(&lx.unqueued, allocator = alloc)
		queue.init(&lx.completed, allocator = alloc)
	case:
		err = ring_err_to_os_err(rerr)
	}

	return
}

_destroy :: proc(io: ^IO) {
	lx := cast(^Linux)io.impl_data
	queue.destroy(&lx.unqueued)
	queue.destroy(&lx.completed)
	free(lx, lx.allocator)
}

_tick :: proc(io: ^IO) -> os.Errno {
	lx := cast(^Linux)io.impl_data

	timeouts: uint = 0
	etime := false

	err := flush(lx, 0, &timeouts, &etime)
	if err != os.ERROR_NONE do return err

	assert(etime == false)

	queued := lx.ring.sq.sqe_tail - lx.ring.sq.sqe_head
	if queued > 0 {
		err = flush_submissions(lx, 0, &timeouts, &etime)
		if err != os.ERROR_NONE do return err
		assert(etime == false)
	}

	return os.ERROR_NONE
}

flush :: proc(lx: ^Linux, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> os.Errno {
	err := flush_submissions(lx, wait_nr, timeouts, etime)
	if err != os.ERROR_NONE do return err

	err = flush_completions(lx, 0, timeouts, etime)
	if err != os.ERROR_NONE do return err


	// Prevent infinite loop when enqueue would add to unqueued,
	// by copying, this makes the loop stop at the last item at the
	// time we start it. New push backs during the loop will be done
	// the next time.
	unqueued_snapshot := lx.unqueued

	// odinfmt: disable
	for unqueued in queue.pop_front_safe(&unqueued_snapshot) {
		switch op in unqueued.operation {
		case Op_Accept:  accept_enqueue(lx, unqueued)
		case Op_Close:   close_enqueue(lx, unqueued)
		case Op_Connect: connect_enqueue(lx, unqueued)
		case Op_Read:    read_enqueue(lx, unqueued)
		case Op_Recv:    recv_enqueue(lx, unqueued)
		case Op_Send:    send_enqueue(lx, unqueued)
		case Op_Write:   write_enqueue(lx, unqueued)
		case Op_Timeout: timeout_enqueue(lx, unqueued)
		}
	}
	// odinfmt: enable

	for completed in queue.pop_front_safe(&lx.completed) {
		completed.callback(lx, completed)
	}

	return os.ERROR_NONE
}

flush_completions :: proc(lx: ^Linux, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> os.Errno {
	cqes: [256]io_uring.io_uring_cqe
	wait_remaining := wait_nr
	for {
		completed, err := io_uring.copy_cqes(&lx.ring, cqes[:], wait_remaining)
		if err != .None do return ring_err_to_os_err(err)

		wait_remaining = max(0, wait_remaining - completed)

		for cqe in cqes[:completed] {
			lx.ios_in_kernel -= 1

			if cqe.user_data == 0 {
				timeouts^ -= 1

				if (-cqe.res == i32(os.ETIME)) {
					etime^ = true
				}
				continue
			}

			completion := cast(^Completion)uintptr(cqe.user_data)
			completion.result = cqe.res

			queue.push_back(&lx.completed, completion)
		}

		if completed < len(cqes) do break
	}

	return os.ERROR_NONE
}

flush_submissions :: proc(lx: ^Linux, wait_nr: u32, timeouts: ^uint, etime: ^bool) -> os.Errno {
	for {
		submitted, err := io_uring.submit(&lx.ring, wait_nr)
		#partial switch err {
		case .None:
			break
		case .Signal_Interrupt:
			continue
		case .Completion_Queue_Overcommitted, .System_Resources:
			ferr := flush_completions(lx, 1, timeouts, etime)
			if ferr != os.ERROR_NONE do return ferr
			continue
		case:
			return ring_err_to_os_err(err)
		}

		lx.ios_queued -= u64(submitted)
		lx.ios_in_kernel += u64(submitted)
		break
	}

	return os.ERROR_NONE
}

_accept :: proc(io: ^IO, socket: os.Socket, user_data: rawptr, callback: Accept_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	op := Op_Accept {
		socket = socket,
		addr_len = size_of(os.SOCKADDR_STORAGE_LH),
	}
	completion.operation = op
	completion.callback = accept_callback

	accept_enqueue(lx, completion)
}

accept_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Accept)

	_, err := io_uring.accept(
		&lx.ring,
		u64(uintptr(completion)),
		op.socket,
		cast(^os.SOCKADDR)&op.addr,
		&op.addr_len,
	)
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

accept_callback :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Accept)
	callback := cast(Accept_Callback)completion.user_callback

	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			accept_enqueue(lx, completion)
			return
		}

		callback(completion.user_data, 0, op.addr, errno)
		free(completion, lx.allocator)
		return
	}

	callback(completion.user_data, os.Socket(completion.result), op.addr, os.ERROR_NONE)
	free(completion, lx.allocator)
}

_close :: proc(io: ^IO, fd: os.Handle, user_data: rawptr, callback: Close_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Close{fd}
	completion.callback = close_callback

	close_enqueue(lx, completion)
}

close_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Close)

	_, err := io_uring.close(&lx.ring, u64(uintptr(completion)), op.fd)
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

close_callback :: proc(lx: ^Linux, completion: ^Completion) {
	callback := cast(Close_Callback)completion.user_callback

	errno := os.Errno(-completion.result)

	// In particular close() should not be retried after an EINTR
	// since this may cause a reused descriptor from another thread to be closed.
	callback(completion.user_data, errno == os.ERROR_NONE || errno == os.EINTR)
	free(completion, lx.allocator)
}

_connect :: proc(io: ^IO, op: Op_Connect, user_data: rawptr, callback: Connect_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = connect_callback

	connect_enqueue(lx, completion)
}

connect_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Connect)

	_, err := io_uring.connect(&lx.ring, u64(uintptr(completion)), op.socket, op.addr, op.len)
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

connect_callback :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Connect)
	callback := cast(Connect_Callback)completion.user_callback

	errno := os.Errno(-completion.result)
	if errno == os.EINTR {
		connect_enqueue(lx, completion)
		return
	}

	callback(completion.user_data, op.socket, errno)
	free(completion, lx.allocator)
}


_read :: proc(io: ^IO, op: Op_Read, user_data: rawptr, callback: Read_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = read_callback

	read_enqueue(lx, completion)
}

read_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Read)

	_, err := io_uring.read(&lx.ring, u64(uintptr(completion)), op.fd, op.buf, u64(op.offset))
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

read_callback :: proc(lx: ^Linux, completion: ^Completion) {
	callback := cast(Read_Callback)completion.user_callback

	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			connect_enqueue(lx, completion)
			return
		}

		callback(completion.user_data, 0, errno)
		free(completion, lx.allocator)
		return
	}

	callback(completion.user_data, int(completion.result), os.ERROR_NONE)
	free(completion, lx.allocator)
}

_recv :: proc(io: ^IO, op: Op_Recv, user_data: rawptr, callback: Recv_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = recv_callback

	recv_enqueue(lx, completion)
}

recv_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Recv)

	_, err := io_uring.recv(&lx.ring, u64(uintptr(completion)), op.socket, op.buf, u32(op.flags))
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}
	// TODO: handle other errors, also in other enqueue procs.

	lx.ios_queued += 1
}

recv_callback :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Recv)
	callback := cast(Recv_Callback)completion.user_callback

	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			recv_enqueue(lx, completion)
			return
		}

		callback(completion.user_data, op.buf, 0, errno)
		free(completion, lx.allocator)
		return
	}

	callback(completion.user_data, op.buf, u32(completion.result), os.ERROR_NONE)
	free(completion, lx.allocator)
}

_send :: proc(io: ^IO, op: Op_Send, user_data: rawptr, callback: Send_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = send_callback

	send_enqueue(lx, completion)
}

send_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Send)

	_, err := io_uring.send(&lx.ring, u64(uintptr(completion)), op.socket, op.buf, u32(op.flags))
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

send_callback :: proc(lx: ^Linux, completion: ^Completion) {
	callback := cast(Send_Callback)completion.user_callback

	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			recv_enqueue(lx, completion)
			return
		}

		callback(completion.user_data, 0, errno)
		free(completion, lx.allocator)
		return
	}

	callback(completion.user_data, u32(completion.result), os.ERROR_NONE)
	free(completion, lx.allocator)
}

_write :: proc(io: ^IO, op: Op_Write, user_data: rawptr, callback: Write_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = op
	completion.callback = write_callback

	write_enqueue(lx, completion)
}

write_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Write)

	_, err := io_uring.write(&lx.ring, u64(uintptr(completion)), op.fd, op.buf, u64(op.offset))
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

write_callback :: proc(lx: ^Linux, completion: ^Completion) {
	callback := cast(Write_Callback)completion.user_callback

	if completion.result < 0 {
		errno := os.Errno(-completion.result)
		if errno == os.EINTR {
			recv_enqueue(lx, completion)
			return
		}

		callback(completion.user_data, 0, errno)
		free(completion, lx.allocator)
		return
	}

	callback(completion.user_data, int(completion.result), os.ERROR_NONE)
	free(completion, lx.allocator)
}

_timeout :: proc(io: ^IO, dur: time.Duration, user_data: rawptr, callback: Timeout_Callback) {
	lx := cast(^Linux)io.impl_data

	completion := new(Completion, lx.allocator)
	completion.user_data = user_data
	completion.user_callback = rawptr(callback)
	completion.operation = Op_Timeout {
		expires = time.time_add(time.now(), dur),
	}
	completion.callback = timeout_callback

	timeout_enqueue(lx, completion)
}

timeout_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := &completion.operation.(Op_Timeout)

	// TODO: does this need to be allocated?
	timeout := time.to_unix_nanoseconds(op.expires)
	ts: os.Unix_File_Time
	ts.nanoseconds = timeout % NANOSECONDS_PER_SECOND
	ts.seconds = timeout / NANOSECONDS_PER_SECOND

	_, err := io_uring.timeout(&lx.ring, u64(uintptr(completion)), &ts, 0, io_uring.IORING_TIMEOUT_ABS)
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	lx.ios_queued += 1
}

timeout_callback :: proc(lx: ^Linux, completion: ^Completion) {
	callback := cast(Timeout_Callback)completion.user_callback

	errno := os.Errno(-completion.result)
	if errno == os.EINTR {
		timeout_enqueue(lx, completion)
		return
	}

	// TODO: we are swallowing the returned error here.
	assert(errno == os.ERROR_NONE)

	callback(completion.user_data)
	free(completion, lx.allocator)
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
