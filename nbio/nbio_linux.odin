package nbio

import "core:container/queue"
import "core:net"
import "core:os"
import "core:sys/unix"
import "core:time"

import io_uring "_io_uring"

_init :: proc(io: ^IO, alloc := context.allocator) -> (err: os.Errno) {
	flags: u32 = 0
	entries: u32 = 256

	io.allocator = alloc

	pool_init(&io.completion_pool, allocator = alloc)

	params: io_uring.io_uring_params

	// Make read, write etc. increment and use the file cursor.
	params.features |= io_uring.IORING_FEAT_RW_CUR_POS

	ring, rerr := io_uring.io_uring_make(&params, entries, flags)
	#partial switch rerr {
	case .None:
		io.ring = ring
		queue.init(&io.unqueued, allocator = alloc)
		queue.init(&io.completed, allocator = alloc)
	case:
		err = ring_err_to_os_err(rerr)
	}

	return
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.completion_pool.num_waiting
}

_destroy :: proc(io: ^IO) {
	queue.destroy(&io.unqueued)
	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	io_uring.io_uring_destroy(&io.ring)
}

_tick :: proc(io: ^IO) -> os.Errno {
	timeouts: uint = 0
	etime := false

	t: unix.timespec
	unix.clock_gettime(unix.CLOCK_MONOTONIC, &t)
	t.tv_nsec += i64(time.Millisecond * 10)

	for !etime {
		// Queue the timeout, if there is an error, flush (cause its probably full) and try again.
		sqe, err := io_uring.timeout(&io.ring, 0, &t, 1, io_uring.IORING_TIMEOUT_ABS)
		if err != nil {
			if errno := flush_submissions(io, 0, &timeouts, &etime); errno != os.ERROR_NONE {
				return errno
			}

			sqe, err = io_uring.timeout(&io.ring, 0, &t, 1, io_uring.IORING_TIMEOUT_ABS)
		}
		if err != nil do return ring_err_to_os_err(err)

		timeouts += 1
		io.ios_queued += 1

		ferr := flush(io, 1, &timeouts, &etime)
		if ferr != os.ERROR_NONE do return ferr
	}

	for timeouts > 0 {
		fcerr := flush_completions(io, 0, &timeouts, &etime)
		if fcerr != os.ERROR_NONE do return fcerr
	}

	return os.ERROR_NONE
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	errno := os.listen(os.Socket(socket), backlog)
	return net.Listen_Error(errno)
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Accept {
		callback    = callback,
		socket      = socket,
		sockaddrlen = i32(size_of(os.SOCKADDR_STORAGE_LH)),
	}

	accept_enqueue(io, completion, &completion.operation.(Op_Accept))
	return completion
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user

	handle: os.Handle
	//odinfmt:disable
	switch h in fd {
	case net.TCP_Socket: handle = os.Handle(h)
	case net.UDP_Socket: handle = os.Handle(h)
	case net.Socket:     handle = os.Handle(h)
	case os.Handle:      handle = h
	} //odinfmt:enable

	completion.operation = Op_Close {
		callback = callback,
		fd       = handle,
	}

	close_enqueue(io, completion, &completion.operation.(Op_Close))
	return completion
}

_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) -> (^Completion, net.Network_Error) {
	if endpoint.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	family := net.family_from_endpoint(endpoint)
	sock, err := net.create_socket(family, .TCP)
	if err != nil {
		return nil, err
	}

	if preperr := _prepare_socket(sock); err != nil {
		close(io, net.any_socket_to_socket(sock))
		return nil, preperr
	}

	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Connect {
		callback = callback,
		socket   = sock.(net.TCP_Socket),
		sockaddr = endpoint_to_sockaddr(endpoint),
	}

	connect_enqueue(io, completion, &completion.operation.(Op_Connect))
	return completion, nil
}

_read :: proc(
	io: ^IO,
	fd: os.Handle,
	offset: Maybe(int),
	buf: []byte,
	user: rawptr,
	callback: On_Read,
	all := false,
) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Read {
		callback = callback,
		fd       = fd,
		buf      = buf,
		offset   = offset.? or_else -1,
		all      = all,
		len      = len(buf),
	}

	read_enqueue(io, completion, &completion.operation.(Op_Read))
	return completion
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Recv {
		callback = callback,
		socket   = socket,
		buf      = buf,
		all      = all,
		len      = len(buf),
	}

	recv_enqueue(io, completion, &completion.operation.(Op_Recv))
	return completion
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	_: Maybe(net.Endpoint) = nil,
	all := false,
) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Send {
		callback = callback,
		socket   = socket,
		buf      = buf,
		all      = all,
		len      = len(buf),
	}

	send_enqueue(io, completion, &completion.operation.(Op_Send))
	return completion
}

_write :: proc(
	io: ^IO,
	fd: os.Handle,
	offset: Maybe(int),
	buf: []byte,
	user: rawptr,
	callback: On_Write,
	all := false,
) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Write {
		callback = callback,
		fd       = fd,
		buf      = buf,
		offset   = offset.? or_else -1,
		all      = all,
		len      = len(buf),
	}

	write_enqueue(io, completion, &completion.operation.(Op_Write))
	return completion
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user

	nsec := time.duration_nanoseconds(dur)
	completion.operation = Op_Timeout {
		callback = callback,
		expires = unix.timespec{
			tv_sec = nsec / NANOSECONDS_PER_SECOND,
			tv_nsec = nsec % NANOSECONDS_PER_SECOND,
		},
	}

	timeout_enqueue(io, completion, &completion.operation.(Op_Timeout))
	return completion
}
