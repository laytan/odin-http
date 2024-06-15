package nbio

import "core:time"

On_Timeout :: #type proc(user: rawptr)

timeout_raw :: #force_inline proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	return _timeout(io, dur, user, callback)
}

On_Next_Tick :: #type proc(user: rawptr)

next_tick_raw :: proc(io: ^IO, user: rawptr, callback: On_Next_Tick) -> ^Completion {
	return _next_tick(io, user, callback)
}
