package nbio

import "base:intrinsics"

import "core:time"

@(private)
memcpy :: intrinsics.mem_copy_non_overlapping

timeout1 :: proc(io: ^IO, dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {

	completion := _timeout(io, dur, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p)
	})

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

timeout2 :: proc(io: ^IO, dur: time.Duration, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {

	completion := _timeout(io, dur, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2)
	})

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

timeout3 :: proc(io: ^IO, dur: time.Duration, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {

	completion := _timeout(io, dur, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

next_tick1 :: proc(io: ^IO, p: $T, callback: $C/proc(p: T)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	completion := _next_tick(io, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)(rawptr(ptr))^
		p   := (^T)(rawptr(ptr + size_of(C)))^
		cb(p)
	})

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                     &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

next_tick2 :: proc(io: ^IO, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	completion := _next_tick(io, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		cb(p, p2)
	})

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                  &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

next_tick3 :: proc(io: ^IO, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	completion := _next_tick(io, nil, proc(completion: rawptr) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C) (rawptr(ptr))^
		p   := (^T) (rawptr(ptr + size_of(C)))^
		p2  := (^T2)(rawptr(ptr + size_of(C) + size_of(T)))^
		p3  := (^T3)(rawptr(ptr + size_of(C) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3)
	})

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}
