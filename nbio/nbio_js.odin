package nbio

import "base:runtime"

import "core:os"
import "core:time"

foreign import "odin_io"

_IO :: struct #no_copy {
	// NOTE: num_waiting is also changed in JS.
	num_waiting: int,
	allocator:   runtime.Allocator,
	// TODO: priority queue, or that other sorted list.
	pending:     [dynamic]^Completion,
	done:        [dynamic]^Completion,
	free_list:   [dynamic]^Completion,
}
#assert(offset_of(_IO, num_waiting) == 0, "Relied upon in JS")

@(private)
_Completion :: struct {
	ctx:     runtime.Context,
	cb:      proc(user: rawptr),
	timeout: time.Time,
}

_init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	io.allocator = allocator
	io.pending.allocator = allocator
	io.done.allocator = allocator
	io.free_list.allocator = allocator
	return os.ERROR_NONE
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.num_waiting
}

_destroy :: proc(io: ^IO) {
	context.allocator = io.allocator
	for c in io.pending {
		free(c)
	}
	delete(io.pending)

	for c in io.done {
		free(c)
	}
	delete(io.done)

	for c in io.free_list {
		free(c)
	}
	delete(io.free_list)
}

_tick :: proc(io: ^IO) -> os.Errno {
	if len(io.pending) > 0 {
		now := time.now()
		#reverse for c, i in io.pending {
			if time.diff(now, c.timeout) <= 0 {
				ordered_remove(&io.pending, i)
				append(&io.done, c)
			}
		}
	}

	for {
		completion := pop_safe(&io.done) or_break
		context = completion.ctx
		completion.cb(completion.user_data)
		io.num_waiting -= 1
		append(&io.free_list, completion)
	}

	return os.ERROR_NONE
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion, ok := pop_safe(&io.free_list)
	if !ok {
		completion = new(Completion, io.allocator)
	}

	completion.ctx = context
	completion.user_data = user
	completion.cb = callback
	completion.timeout = time.time_add(time.now(), dur)

	io.num_waiting += 1
	append(&io.pending, completion)
	return completion
}

_next_tick :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	completion, ok := pop_safe(&io.free_list)
	if !ok {
		completion = new(Completion, io.allocator)
	}

	completion.ctx = context
	completion.user_data = user
	completion.cb = callback

	io.num_waiting += 1
	append(&io.done, completion)
	return completion
}

_timeout_completion :: proc(io: ^IO, dur: time.Duration, target: ^Completion) -> ^Completion {
	// NOTE: none of the operations we support for JS, are able to timeout on other targets.
	panic("trying to add a timeout to an operation that can't timeout")
}

_timeout_remove :: proc(io: ^IO, timeout: ^Completion) {
	// NOTE: none of the operations we support for JS, are able to timeout on other targets.
	panic("trying to add a timeout to an operation that can't timeout")
}
