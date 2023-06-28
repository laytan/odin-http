//+build linux
//+private
package nbio

import "core:os"
import "core:time"
import "core:mem"
import "core:container/queue"

import "../io_uring"

Linux :: struct {
	ring: io_uring.IO_Uring,

	// Ready to be submitted to kernel.
	unqueued: queue.Queue(^Completion),
	// Ready to run callbacks.
	completed: queue.Queue(^Completion),

	ios_queued: u64,
	ios_in_kernel: u64,

	allocator: mem.Allocator,
}

Completion :: struct {
	lx:            ^Linux,
	result:        i32,
	next:          ^Completion,
	operation:     Operation,
	callback:      proc(lx: ^Linux, c: ^Completion),
	user_callback: rawptr,
	user_data:     rawptr,
}

_init :: proc(io: ^IO, entries: u32 = DEFAULT_ENTRIES, flags: u32 = 0, allocator := context.allocator) -> (err: os.Errno) {
	lx := new(Linux, allocator)

	lx.allocator = allocator

	params: io_uring.io_uring_params
	ring, rerr := io_uring.io_uring_make(&params, entries, flags)
	#partial switch rerr {
	case .None:
		lx.ring = ring
		queue.init(&lx.unqueued, allocator=allocator)
		queue.init(&lx.completed, allocator=allocator)
	case .Params_Outside_Accessible_Address_Space:
		err = os.EFAULT
	case .Arguments_Invalid:
		err = os.EINVAL
	case .Process_Fd_Quota_Exceeded:
		err = os.EMFILE
	case .System_Fd_Quota_Exceeded:
		err = os.ENFILE
	case .System_Resources:
		err = os.ENOMEM
	case .Permission_Denied:
		err = os.EPERM
	case .System_Outdated:
		err = os.ENOSYS
	case:
		err = -1
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

	timeouts : uint = 0
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

	// TODO: see if correct
	for unqueued in queue.pop_front_safe(&lx.unqueued) {
		switch op in unqueued.operation {
		case Op_Accept: enqueue_accept(lx, unqueued)
		}
	}

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
		assert(err == .None) // TODO: convert to os.Errno and return.
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
		case .Signal_Interrupt: continue
		case .Completion_Queue_Overcommitted, .System_Resources:
			ferr := flush_completions(lx, 1, timeouts, etime)
			if ferr != os.ERROR_NONE do return ferr
			continue
		}
		// TODO: convert to os err and return.
		assert(err != nil)

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
	op := Op_Accept{socket = socket}
	completion.operation = op
	completion.callback = accept_callback
	accept_enqueue(lx, completion)
}

accept_enqueue :: proc(lx: ^Linux, completion: ^Completion) {
	op := completion.operation.(Op_Accept)
	sqe, err := io_uring.accept(&lx.ring, u64(uintptr(completion)), op.socket, cast(^os.SOCKADDR)&op.addr, &op.addr_len)
	if err == .Submission_Queue_Full {
		queue.push_back(&lx.unqueued, completion)
		return
	}

	sqe.user_data = u64(uintptr(completion))

	lx.ios_queued += 1
}

accept_callback :: proc(lx: ^Linux, completion: ^Completion) {
	op := completion.operation.(Op_Accept)
	callback := cast(Accept_Callback)completion.user_callback

	err := os.ERROR_NONE
	if completion.result < 0 {
		// TODO: feels weird, is this correct?
		err = os.Errno(-completion.result)
	}

	callback(completion.user_data, op.socket, op.addr, os.socklen_t(op.addr_len), err)
}

_close :: proc(io: ^IO, fd: os.Handle, user_data: rawptr, callback: Close_Callback) {
	lx := cast(^Linux)io.impl_data
}

_connect :: proc(io: ^IO, op: Op_Connect, user_data: rawptr, callback: Connect_Callback) {
	lx := cast(^Linux)io.impl_data
}

_read :: proc(io: ^IO, op: Op_Read, user_data: rawptr, callback: Read_Callback) {
	lx := cast(^Linux)io.impl_data
}

_recv :: proc(io: ^IO, op: Op_Recv, user_data: rawptr, callback: Recv_Callback) {
	lx := cast(^Linux)io.impl_data
}

_send :: proc(io: ^IO, op: Op_Send, user_data: rawptr, callback: Send_Callback) {
	lx := cast(^Linux)io.impl_data
}

_write :: proc(io: ^IO, op: Op_Write, user_data: rawptr, callback: Write_Callback) {
	lx := cast(^Linux)io.impl_data
}

_timeout :: proc(io: ^IO, dur: time.Duration, user_data: rawptr, callback: Timeout_Callback) {
	lx := cast(^Linux)io.impl_data
}
