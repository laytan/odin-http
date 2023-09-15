//+build linux
package io_uring

import "core:math"
import "core:os"
import "core:sync"
import "core:sys/unix"

DEFAULT_THREAD_IDLE_MS :: 1000
DEFAULT_ENTRIES :: 32
MAX_ENTRIES :: 4096

IO_Uring_Error :: enum {
	None,
	Entries_Zero,
	Entries_Not_Power_Of_Two,
	Entries_Too_Large,
	Params_Outside_Accessible_Address_Space,
	Arguments_Invalid,
	Process_Fd_Quota_Exceeded,
	System_Fd_Quota_Exceeded,
	System_Resources,
	Permission_Denied,
	System_Outdated,
	Submission_Queue_Full,
	File_Descriptor_Invalid,
	Completion_Queue_Overcommitted,
	Submission_Queue_Entry_Invalid,
	Buffer_Invalid,
	Ring_Shutting_Down,
	Opcode_Not_Supported,
	Signal_Interrupt,
	Unexpected,
}

IO_Uring :: struct {
	fd:       os.Handle,
	sq:       Submission_Queue,
	cq:       Completion_Queue,
	flags:    u32,
	features: u32,
}

// Set up an IO_Uring with default parameters, `entries` must be a power of 2 between 1 and 4096.
io_uring_make :: proc(
	params: ^io_uring_params,
	entries: u32 = DEFAULT_ENTRIES,
	flags: u32 = 0,
) -> (
	ring: IO_Uring,
	err: IO_Uring_Error,
) {
	params.flags = flags
	params.sq_thread_idle = DEFAULT_THREAD_IDLE_MS
	err = io_uring_init(&ring, entries, params)
	return
}

// Initialize and setup a io_uring with more control than io_uring_make.
io_uring_init :: proc(ring: ^IO_Uring, entries: u32, params: ^io_uring_params) -> (err: IO_Uring_Error) {
	check_entries(entries) or_return

	res := sys_io_uring_setup(entries, params)
	if res < 0 {
		switch os.Errno(-res) {
		case os.EFAULT:
			return .Params_Outside_Accessible_Address_Space
		// The resv array contains non-zero data, p.flags contains an unsupported flag,
		// entries out of bounds, IORING_SETUP_SQ_AFF was specified without IORING_SETUP_SQPOLL,
		// or IORING_SETUP_CQSIZE was specified but linux.io_uring_params.cq_entries was invalid:
		case os.EINVAL:
			return .Arguments_Invalid
		case os.EMFILE:
			return .Process_Fd_Quota_Exceeded
		case os.ENFILE:
			return .System_Fd_Quota_Exceeded
		case os.ENOMEM:
			return .System_Resources
		// IORING_SETUP_SQPOLL was specified but effective user ID lacks sufficient privileges,
		// or a container seccomp policy prohibits io_uring syscalls:
		case os.EPERM:
			return .Permission_Denied
		case os.ENOSYS:
			return .System_Outdated
		case:
			return .Unexpected
		}
	}

	fd := os.Handle(res)

	// Unsupported features.
	assert((params.features & IORING_FEAT_SINGLE_MMAP) != 0)
	assert((params.flags & IORING_SETUP_CQE32) == 0)
	assert((params.flags & IORING_SETUP_SQE128) == 0)

	sq, ok := submission_queue_make(fd, params)
	if !ok do return .System_Resources

	ring.fd = fd
	ring.sq = sq
	ring.cq = completion_queue_make(fd, params, &sq)
	ring.flags = params.flags
	ring.features = params.features

	return
}

// Checks if the entries conform to the kernel rules.
@(private)
check_entries :: proc(entries: u32) -> (err: IO_Uring_Error) {
	switch {
	case entries >= MAX_ENTRIES:
		err = .Entries_Too_Large
	case entries == 0:
		err = .Entries_Zero
	case !math.is_power_of_two(int(entries)):
		err = .Entries_Not_Power_Of_Two
	case:
		err = .None
	}
	return
}

io_uring_destroy :: proc(ring: ^IO_Uring) {
	assert(ring.fd >= 0)
	submission_queue_destroy(&ring.sq)
	os.close(ring.fd)
	ring.fd = -1
}

// Returns a pointer to a vacant submission queue entry, or an error if the submission queue is full.
get_sqe :: proc(ring: ^IO_Uring) -> (sqe: ^io_uring_sqe, err: IO_Uring_Error) {
	sq := &ring.sq
	head: u32 = sync.atomic_load_explicit(sq.head, .Acquire)
	next := sq.sqe_tail + 1

	if int(next - head) > len(sq.sqes) {
		err = .Submission_Queue_Full
		return
	}

	sqe = &sq.sqes[sq.sqe_tail & sq.mask]
	sqe^ = {}

	sq.sqe_tail = next
	return
}

// Submits the submission queue entries acquired via get_sqe().
// Returns the number of entries submitted.
// Optionally wait for a number of events by setting wait_nr.
submit :: proc(ring: ^IO_Uring, wait_nr: u32 = 0) -> (n_submitted: u32, err: IO_Uring_Error) {
	n_submitted = flush_sq(ring)
	flags: u32 = 0
	if sq_ring_needs_enter(ring, &flags) || wait_nr > 0 {
		if wait_nr > 0 || ring.flags & IORING_SETUP_IOPOLL != 0 {
			flags |= IORING_ENTER_GETEVENTS
		}
		n_submitted, err = enter(ring, n_submitted, wait_nr, flags)
	}
	return
}

// Tells the kernel that submission queue entries were submitted and/or we want to wait for their completion queue entries.
// Returns the number of submission queue entries that were submitted.
enter :: proc(
	ring: ^IO_Uring,
	n_to_submit: u32,
	min_complete: u32,
	flags: u32,
) -> (
	n_submitted: u32,
	err: IO_Uring_Error,
) {
	assert(ring.fd >= 0)
	ns := sys_io_uring_enter(u32(ring.fd), n_to_submit, min_complete, flags, nil)
	if ns < 0 {
		switch os.Errno(-ns) {
		case os.ERROR_NONE:
			err = .None
		case os.EAGAIN:
			// The kernel was unable to allocate memory or ran out of resources for the request. (try again)
			err = .System_Resources
		case os.EBADF:
			// The SQE `fd` is invalid, or `IOSQE_FIXED_FILE` was set but no files were registered
			err = .File_Descriptor_Invalid
		// case os.EBUSY: // TODO: why is this not in os_linux
		// 	// Attempted to overcommit the number of requests it can have pending. Should wait for some completions and try again.
		// 	err = .Completion_Queue_Overcommitted
		case os.EINVAL:
			// The SQE is invalid, or valid but the ring was setup with `IORING_SETUP_IOPOLL`
			err = .Submission_Queue_Entry_Invalid
		case os.EFAULT:
			// The buffer is outside the process' accessible address space, or `IORING_OP_READ_FIXED`
			// or `IORING_OP_WRITE_FIXED` was specified but no buffers were registered, or the range
			// described by `addr` and `len` is not within the buffer registered at `buf_index`
			err = .Buffer_Invalid
		case os.ENXIO:
			err = .Ring_Shutting_Down
		case os.EOPNOTSUPP:
			// The kernel believes the `fd` doesn't refer to an `io_uring`, or the opcode isn't supported by this kernel (more likely)
			err = .Opcode_Not_Supported
		case os.EINTR:
			// The op was interrupted by a delivery of a signal before it could complete.This can happen while waiting for events with `IORING_ENTER_GETEVENTS`
			err = .Signal_Interrupt
		case:
			err = .Unexpected
		}
		return
	}

	n_submitted = u32(ns)
	return
}

// Sync internal state with kernel ring state on the submission queue side.
// Returns the number of all pending events in the submission queue.
// Rationale is to determine that an enter call is needed.
flush_sq :: proc(ring: ^IO_Uring) -> (n_pending: u32) {
	sq := &ring.sq
	to_submit := sq.sqe_tail - sq.sqe_head
	if to_submit != 0 {
		tail := sq.tail^
		i: u32 = 0
		for ; i < to_submit; i += 1 {
			sq.array[tail & sq.mask] = sq.sqe_head & sq.mask
			tail += 1
			sq.sqe_head += 1
		}
		sync.atomic_store_explicit(sq.tail, tail, .Release)
	}
	n_pending = sq_ready(ring)
	return
}

// Returns true if we are not using an SQ thread (thus nobody submits but us),
// or if IORING_SQ_NEED_WAKEUP is set and the SQ thread must be explicitly awakened.
// For the latter case, we set the SQ thread wakeup flag.
// Matches the implementation of sq_ring_needs_enter() in liburing.
sq_ring_needs_enter :: proc(ring: ^IO_Uring, flags: ^u32) -> bool {
	assert(flags^ == 0)
	if ring.flags & IORING_SETUP_SQPOLL == 0 do return true
	if sync.atomic_load_explicit(ring.sq.flags, .Relaxed) & IORING_SQ_NEED_WAKEUP != 0 {
		flags^ |= IORING_ENTER_SQ_WAKEUP
		return true
	}
	return false
}

// Returns the number of submission queue entries in the submission queue.
sq_ready :: proc(ring: ^IO_Uring) -> u32 {
	// Always use the shared ring state (i.e. head and not sqe_head) to avoid going out of sync,
	// see https://github.com/axboe/liburing/issues/92.
	return ring.sq.sqe_tail - sync.atomic_load_explicit(ring.sq.head, .Acquire)
}

// Returns the number of completion queue entries in the completion queue (yet to consume).
cq_ready :: proc(ring: ^IO_Uring) -> (n_ready: u32) {
	return sync.atomic_load_explicit(ring.cq.tail, .Acquire) - ring.cq.head^
}

// Copies as many CQEs as are ready, and that can fit into the destination `cqes` slice.
// If none are available, enters into the kernel to wait for at most `wait_nr` CQEs.
// Returns the number of CQEs copied, advancing the CQ ring.
// Provides all the wait/peek methods found in liburing, but with batching and a single method.
copy_cqes :: proc(ring: ^IO_Uring, cqes: []io_uring_cqe, wait_nr: u32) -> (n_copied: u32, err: IO_Uring_Error) {
	n_copied = copy_cqes_ready(ring, cqes)
	if n_copied > 0 do return
	if wait_nr > 0 || cq_ring_needs_flush(ring) {
		_ = enter(ring, 0, wait_nr, IORING_ENTER_GETEVENTS) or_return
		n_copied = copy_cqes_ready(ring, cqes)
	}
	return
}

copy_cqes_ready :: proc(ring: ^IO_Uring, cqes: []io_uring_cqe) -> (n_copied: u32) {
	n_ready := cq_ready(ring)
	n_copied = min(u32(len(cqes)), n_ready)
	head := ring.cq.head^
	tail := head + n_copied

	i := 0
	for head != tail {
		cqes[i] = ring.cq.cqes[head & ring.cq.mask]
		head += 1
		i += 1
	}
	cq_advance(ring, n_copied)
	return
}

cq_ring_needs_flush :: proc(ring: ^IO_Uring) -> bool {
	return sync.atomic_load_explicit(ring.sq.flags, .Relaxed) & IORING_SQ_CQ_OVERFLOW != 0
}

// For advanced use cases only that implement custom completion queue methods.
// If you use copy_cqes() or copy_cqe() you must not call cqe_seen() or cq_advance().
// Must be called exactly once after a zero-copy CQE has been processed by your application.
// Not idempotent, calling more than once will result in other CQEs being lost.
// Matches the implementation of cqe_seen() in liburing.
cqe_seen :: proc(ring: ^IO_Uring) {
	cq_advance(ring, 1)
}

// For advanced use cases only that implement custom completion queue methods.
// Matches the implementation of cq_advance() in liburing.
cq_advance :: proc(ring: ^IO_Uring, count: u32) {
	if count == 0 do return
	sync.atomic_store_explicit(ring.cq.head, ring.cq.head^ + count, .Release)
}

// Queues (but does not submit) an SQE to perform an `fsync(2)`.
// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
fsync :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	fd: os.Handle,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .FSYNC
	sqe.rw_flags = i32(flags)
	sqe.fd = i32(fd)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a no-op.
// Returns a pointer to the SQE so that you can further modify the SQE for advanced use cases.
// A no-op is more useful than may appear at first glance.
// For example, you could call `drain_previous_sqes()` on the returned SQE, to use the no-op to
// know when the ring is idle before acting on a kill signal.
nop :: proc(ring: ^IO_Uring, user_data: u64) -> (sqe: ^io_uring_sqe, err: IO_Uring_Error) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .NOP
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `read(2)`.
read :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	fd: os.Handle,
	buf: []u8,
	offset: u64,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .READ
	sqe.fd = i32(fd)
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.off = offset
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `write(2)`.
write :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	fd: os.Handle,
	buf: []u8,
	offset: u64,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = .WRITE
	sqe.fd = i32(fd)
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.off = offset
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform an `accept4(2)` on a socket.
// `addr`,`addr_len` optional
accept :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	sockfd: os.Socket,
	addr: ^os.SOCKADDR = nil,
	addr_len: ^os.socklen_t = nil,
	flags: u32 = 0,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.ACCEPT
	sqe.fd = i32(sockfd)
	sqe.addr = cast(u64)uintptr(addr)
	sqe.off = cast(u64)uintptr(addr_len)
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

// Queue (but does not submit) an SQE to perform a `connect(2)` on a socket.
connect :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	sockfd: os.Socket,
	addr: ^os.SOCKADDR,
	addr_len: os.socklen_t,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.CONNECT
	sqe.fd = i32(sockfd)
	sqe.addr = cast(u64)uintptr(addr)
	sqe.off = cast(u64)addr_len
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `recv(2)`.
recv :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	sockfd: os.Socket,
	buf: []byte,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.RECV
	sqe.fd = i32(sockfd)
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = cast(u32)uintptr(len(buf))
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `send(2)`.
send :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	sockfd: os.Socket,
	buf: []byte,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.SEND
	sqe.fd = i32(sockfd)
	sqe.addr = cast(u64)uintptr(raw_data(buf))
	sqe.len = u32(len(buf))
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform an `openat(2)`.
openat :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	fd: os.Handle,
	path: cstring,
	mode: u32,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.OPENAT
	sqe.fd = i32(fd)
	sqe.addr = cast(u64)transmute(uintptr)path
	sqe.len = cast(u32)mode
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to perform a `close(2)`.
close :: proc(ring: ^IO_Uring, user_data: u64, fd: os.Handle) -> (sqe: ^io_uring_sqe, err: IO_Uring_Error) {
	sqe, err = get_sqe(ring)
	if err != .None {return}
	sqe.opcode = IORING_OP.CLOSE
	sqe.fd = i32(fd)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to register a timeout operation.
// Returns a pointer to the SQE.
//
// The timeout will complete when either the timeout expires, or after the specified number of
// events complete (if `count` is greater than `0`).
//
// `flags` may be `0` for a relative timeout, or `IORING_TIMEOUT_ABS` for an absolute timeout.
//
// The completion event result will be `-ETIME` if the timeout completed through expiration,
// `0` if the timeout completed after the specified number of events, or `-ECANCELED` if the
// timeout was removed before it expired.
//
// io_uring timeouts use the `CLOCK.MONOTONIC` clock source.
timeout :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	ts: ^unix.timespec,
	count: u32,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.TIMEOUT
	sqe.fd = -1
	sqe.addr = transmute(u64)uintptr(ts)
	sqe.len = 1
	sqe.off = u64(count)
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to remove an existing timeout operation.
// Returns a pointer to the SQE.
//
// The timeout is identified by its `user_data`.
//
// The completion event result will be `0` if the timeout was found and cancelled successfully,
// `-EBUSY` if the timeout was found but expiration was already in progress, or
// `-ENOENT` if the timeout was not found.
timeout_remove :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	timeout_user_data: u64,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.TIMEOUT_REMOVE
	sqe.fd = -1
	sqe.addr = timeout_user_data
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

// Queues (but does not submit) an SQE to add a link timeout operation.
// Returns a pointer to the SQE.
//
// You need to set linux.IOSQE_IO_LINK to flags of the target operation
// and then call this method right after the target operation.
// See https://lwn.net/Articles/803932/ for detail.
//
// If the dependent request finishes before the linked timeout, the timeout
// is canceled. If the timeout finishes before the dependent request, the
// dependent request will be canceled.
//
// The completion event result of the link_timeout will be
// `-ETIME` if the timeout finishes before the dependent request
// (in this case, the completion event result of the dependent request will
// be `-ECANCELED`), or
// `-EALREADY` if the dependent request finishes before the linked timeout.
link_timeout :: proc(
	ring: ^IO_Uring,
	user_data: u64,
	ts: ^os.Unix_File_Time,
	flags: u32,
) -> (
	sqe: ^io_uring_sqe,
	err: IO_Uring_Error,
) {
	sqe = get_sqe(ring) or_return
	sqe.opcode = IORING_OP.LINK_TIMEOUT
	sqe.fd = -1
	sqe.addr = transmute(u64)uintptr(ts)
	sqe.len = 1
	sqe.rw_flags = i32(flags)
	sqe.user_data = user_data
	return
}

Submission_Queue :: struct {
	head:      ^u32,
	tail:      ^u32,
	mask:      u32,
	flags:     ^u32,
	dropped:   ^u32,
	array:     []u32,
	sqes:      []io_uring_sqe,
	mmap:      []u8,
	mmap_sqes: []u8,

	// We use `sqe_head` and `sqe_tail` in the same way as liburing:
	// We increment `sqe_tail` (but not `tail`) for each call to `get_sqe()`.
	// We then set `tail` to `sqe_tail` once, only when these events are actually submitted.
	// This allows us to amortize the cost of the @atomicStore to `tail` across multiple SQEs.
	sqe_head:  u32,
	sqe_tail:  u32,
}

submission_queue_make :: proc(fd: os.Handle, params: ^io_uring_params) -> (sq: Submission_Queue, ok: bool) {
	assert(fd >= 0)
	// Unsupported feature.
	assert((params.features & IORING_FEAT_SINGLE_MMAP) != 0)

	sq_size := params.sq_off.array + params.sq_entries * size_of(u32)
	cq_size := params.cq_off.cqes + params.cq_entries * size_of(io_uring_cqe)
	size := max(sq_size, cq_size)

	mmap_result := unix.sys_mmap(
		nil,
		uint(size),
		unix.PROT_READ | unix.PROT_WRITE,
		unix.MAP_SHARED,
		/* | unix.MAP_POPULATE */
		int(fd),
		IORING_OFF_SQ_RING,
	)
	if mmap_result < 0 do return
	defer if !ok do unix.sys_munmap(rawptr(uintptr(mmap_result)), uint(size))

	mmap := transmute([^]u8)uintptr(mmap_result)

	size_sqes := params.sq_entries * size_of(io_uring_sqe)
	mmap_sqes_result := unix.sys_mmap(
		nil,
		uint(size_sqes),
		unix.PROT_READ | unix.PROT_WRITE,
		unix.MAP_SHARED,
		/* | unix.MAP_POPULATE */
		int(fd),
		IORING_OFF_SQES,
	)
	if mmap_sqes_result < 0 do return

	array := transmute([^]u32)&mmap[params.sq_off.array]
	sqes := transmute([^]io_uring_sqe)uintptr(mmap_sqes_result)
	mmap_sqes := transmute([^]u8)uintptr(mmap_sqes_result)


	sq.head = transmute(^u32)&mmap[params.sq_off.head]
	sq.tail = transmute(^u32)&mmap[params.sq_off.tail]
	sq.mask = (transmute(^u32)&mmap[params.sq_off.ring_mask])^
	sq.flags = transmute(^u32)&mmap[params.sq_off.flags]
	sq.dropped = transmute(^u32)&mmap[params.sq_off.dropped]
	sq.array = array[:params.sq_entries]
	sq.sqes = sqes[:params.sq_entries]
	sq.mmap = mmap[:size]
	sq.mmap_sqes = mmap_sqes[:size_sqes]

	ok = true
	return
}

submission_queue_destroy :: proc(sq: ^Submission_Queue) {
	unix.sys_munmap(raw_data(sq.mmap), uint(len(sq.mmap)))
	unix.sys_munmap(raw_data(sq.mmap_sqes), uint(len(sq.mmap)))
}

Completion_Queue :: struct {
	head:     ^u32,
	tail:     ^u32,
	mask:     u32,
	overflow: ^u32,
	cqes:     []io_uring_cqe,
}

completion_queue_make :: proc(fd: os.Handle, params: ^io_uring_params, sq: ^Submission_Queue) -> Completion_Queue {
	assert(fd >= 0)
	// Unsupported feature.
	assert((params.features & IORING_FEAT_SINGLE_MMAP) != 0)

	mmap := sq.mmap
	cqes := transmute([^]io_uring_cqe)&mmap[params.cq_off.cqes]

	return(
		{
			head = transmute(^u32)&mmap[params.cq_off.head],
			tail = transmute(^u32)&mmap[params.cq_off.tail],
			mask = (transmute(^u32)&mmap[params.cq_off.ring_mask])^,
			overflow = transmute(^u32)&mmap[params.cq_off.overflow],
			cqes = cqes[:params.cq_entries],
		} \
	)
}
