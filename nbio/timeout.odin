package nbio

import "core:time"


// If event completes first, change timeout duration to 0 so it runs it the next iteration.
// The timeout will be responsible of cleaning up always.

// If timeout completes first, add an event to the queue to delete the completion, and call the callback with an error.

// timeout_completion :: proc(io: ^IO, completion: ^Completion, duration: time.Duration) {
// 	context.user_ptr = io
// 	completion.timeout = timeout(io, duration, completion, proc(completion: rawptr, _: Maybe(time.Time)) {
// 		io := (^IO)(context.user_ptr)
// 		// TODO: Remove it from everything.
//
// 		completion := (^Completion)(completion)
//
// // 		cancellation pool_get(&io.pool) })
// }

