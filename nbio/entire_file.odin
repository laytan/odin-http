//+build !js
package nbio

import "core:os"

read_entire_file :: proc {
	read_entire_file1,
	read_entire_file2,
	read_entire_file3,
}

read_entire_file1 :: proc(io: ^IO, fd: os.Handle, p: $T, callback: $C/proc(p: T, buf: []byte, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of([]byte) <= MAX_USER_ARGUMENTS {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(p, nil, err)
		return nil
	}

	if size <= 0 {
		callback(p, nil, os.ERROR_NONE)
		return nil
	}

	buf := make([]byte, size, allocator)

	completion := _read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)     (rawptr(ptr))^
		buf := (^[]byte)(rawptr(ptr + size_of(C)))^
		p   := (^T)     (rawptr(ptr + size_of(C) + size_of([]byte)))^
		cb(p, buf, err)
	}, all = true)

	callback, p := callback, p
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                    &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                &buf,      size_of(buf))
	memcpy(rawptr(ptr + size_of(callback) + size_of(buf)), &p,        size_of(p))

	completion.user_data = completion
	return completion
}

read_entire_file2 :: proc(io: ^IO, fd: os.Handle, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, buf: []byte, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of(T2) + size_of([]byte) <= MAX_USER_ARGUMENTS {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(p, p2, nil, err)
		return nil
	}

	if size <= 0 {
		callback(p, p2, nil, os.ERROR_NONE)
		return nil
	}

	buf := make([]byte, size, allocator)

	completion := _read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)     (rawptr(ptr))^
		buf := (^[]byte)(rawptr(ptr + size_of(C)))^
		p   := (^T)     (rawptr(ptr + size_of(C) + size_of([]byte)))^
		p2  := (^T2)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T)))^
		cb(p, p2, buf, err)
	}, all = true)

	callback, p, p2 := callback, p, p2
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                 &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                             &buf,      size_of(buf))
	memcpy(rawptr(ptr + size_of(callback) + size_of(buf)),              &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(buf) + size_of(p)), &p2,       size_of(p2))

	completion.user_data = completion
	return completion
}

read_entire_file3 :: proc(io: ^IO, fd: os.Handle, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, buf: []byte, err: os.Errno), allocator := context.allocator) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) + size_of([]byte) <= MAX_USER_ARGUMENTS {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(p, p2, p3, nil, err)
		return nil
	}

	if size <= 0 {
		callback(p, p2, p3, nil, os.ERROR_NONE)
		return nil
	}

	buf := make([]byte, size, allocator)

	completion := _read(io, fd, 0, buf, nil, proc(completion: rawptr, read: int, err: os.Errno) {
		ptr := uintptr(&((^Completion)(completion)).user_args)
		cb  := (^C)     (rawptr(ptr))^
		buf := (^[]byte)(rawptr(ptr + size_of(C)))^
		p   := (^T)     (rawptr(ptr + size_of(C) + size_of([]byte)))^
		p2  := (^T2)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T)))^
		p3  := (^T3)    (rawptr(ptr + size_of(C) + size_of([]byte) + size_of(T) + size_of(T2)))^
		cb(p, p2, p3, buf, err)
	}, all = true)

	callback, p, p2, p3 := callback, p, p2, p3
	ptr := uintptr(&completion.user_args)

	memcpy(rawptr(ptr),                                                               &callback, size_of(callback))
	memcpy(rawptr(ptr + size_of(callback)),                                           &buf,      size_of(buf))
	memcpy(rawptr(ptr + size_of(callback) + size_of(buf)),                            &p,        size_of(p))
	memcpy(rawptr(ptr + size_of(callback) + size_of(buf) + size_of(p)),               &p2,       size_of(p2))
	memcpy(rawptr(ptr + size_of(callback) + size_of(buf) + size_of(p) + size_of(p2)), &p3,       size_of(p3))

	completion.user_data = completion
	return completion
}

write_entire_file :: proc {
	write_entire_file1,
	write_entire_file2,
	write_entire_file3,
}

write_entire_file1 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, callback: $C/proc(p: T, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) <= MAX_USER_ARGUMENTS {
	return write_at_all1(io, fd, 0, buf, p, callback)
}

write_entire_file2 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, callback: $C/proc(p: T, p2: T2, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) <= MAX_USER_ARGUMENTS {
	return write_at_all2(io, fd, 0, buf, p, p2, callback)
}

write_entire_file3 :: #force_inline proc(io: ^IO, fd: os.Handle, buf: []byte, p: $T, p2: $T2, p3: $T3, callback: $C/proc(p: T, p2: T2, p3: T3, written: int, err: os.Errno)) -> ^Completion
	where size_of(T) + size_of(T2) + size_of(T3) <= MAX_USER_ARGUMENTS {
	return write_at_all3(io, fd, 0, buf, p, p2, p3, callback)
}
