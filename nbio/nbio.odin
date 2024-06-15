package nbio

import "core:os"
import "core:time"

/*
The main IO type that holds the platform dependant implementation state passed around most procedures in this package
*/
IO :: _IO

/*
Initializes the IO type, allocates different things per platform needs

*Allocates Using Provided Allocator*

Inputs:
- io:        The IO struct to initialize
- allocator: (default: context.allocator)

Returns:
- err: An error code when something went wrong with the setup of the platform's IO API, 0 otherwise
*/
init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	return _init(io, allocator)
}

/*
The place where the magic happens, each time you call this the IO implementation checks its state
and calls any callbacks which are ready. You would typically call this in a loop

Inputs:
- io: The IO instance to tick

Returns:
- err: An error code when something went when retrieving events, 0 otherwise
*/
tick :: proc(io: ^IO) -> os.Errno {
	return _tick(io)
}

run :: proc(io: ^IO) -> os.Errno {
	for num_waiting(io) > 0 {
		if errno := tick(io); errno != 0 {
			return errno
		}
	}
	return 0
}

/*
Returns the number of in-progress IO to be completed.
*/
num_waiting :: #force_inline proc(io: ^IO) -> int {
	return _num_waiting(io)
}

/*
Deallocates anything that was allocated when calling init()

Inputs:
- io: The IO instance to deallocate

*Deallocates with the allocator that was passed with the init() call*
*/
destroy :: proc(io: ^IO) {
	_destroy(io)
}

/*
Schedules a callback to be called after the given duration elapses.

The accuracy depends on the time between calls to `tick`.
When you call it in a loop with no blocks or very expensive calculations in other scheduled event callbacks
it is reliable to about a ms of difference (so timeout of 10ms would almost always be ran between 10ms and 11ms).

Inputs:
- io:       The IO instance to use
- dur:      The minimum duration to wait before calling the given callback
*/
timeout :: proc {
	timeout_raw,
	timeout1,
	timeout2,
	timeout3,
}

/*
Schedules a callback to be called during the next tick of the event loop.

Inputs:
- io:   The IO instance to use
*/
next_tick :: proc {
	next_tick_raw,
	next_tick1,
	next_tick2,
	next_tick3,
}

/*
Removes the given target from the event loop.

Common use would be to cancel a timeout, remove a polling, or remove an `accept` before calling `close` on it's socket.
*/
remove :: proc(io: ^IO, target: ^Completion) {
	if target == nil {
		return
	}

	_remove(io, target)
}

// TODO: document.
with_timeout :: proc(io: ^IO, dur: time.Duration, target: ^Completion, loc := #caller_location) -> ^Completion {
	if target == nil do return nil
	if dur == 0 do return nil

	return _timeout_completion(io, dur, target)
}

MAX_USER_ARGUMENTS :: size_of(rawptr) * 5

Completion :: struct {
	// Implementation specifics, don't use outside of implementation/os.
	using _:   _Completion,

	user_data: rawptr,

	// Callback pointer and user args passed in poly variants.
	user_args: [MAX_USER_ARGUMENTS + size_of(rawptr)]byte,
}
