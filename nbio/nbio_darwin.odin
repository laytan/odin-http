package nbio

import "core:container/queue"
import "core:net"
import "core:os"
import "core:time"

import kqueue "_kqueue"

_init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	qerr: kqueue.Queue_Error
	io.kq, qerr = kqueue.kqueue()
	if qerr != .None do return kq_err_to_os_err(qerr)

	pool_init(&io.completion_pool, allocator = allocator)

	io.timeouts = make([dynamic]^Completion, allocator)
	io.io_pending = make([dynamic]^Completion, allocator)

	queue.init(&io.completed, allocator = allocator)

	io.allocator = allocator
	return
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.completion_pool.num_waiting
}

_destroy :: proc(io: ^IO) {
	delete(io.timeouts)
	delete(io.io_pending)

	queue.destroy(&io.completed)

	os.close(io.kq)

	pool_destroy(&io.completion_pool)
}

_tick :: proc(io: ^IO) -> os.Errno {
	return flush(io)
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> net.Network_Error {
	errno := os.listen(os.Socket(socket), backlog)
	return net.Listen_Error(errno)
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx       = context
	completion.user_data = user
	completion.operation = Op_Accept{
		callback = callback,
		sock     = socket,
	}

	queue.push_back(&io.completed, completion)
	return completion
}

// Wraps os.close using the kqueue.
_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx           = context
	completion.user_data     = user

	completion.operation = Op_Close{
		callback = callback,
	}
	op := &completion.operation.(Op_Close)

	switch h in fd {
	case net.TCP_Socket: op.handle = os.Handle(h)
	case net.UDP_Socket: op.handle = os.Handle(h)
	case net.Socket:     op.handle = os.Handle(h)
	case os.Handle:      op.handle = h
	}

	queue.push_back(&io.completed, completion)
	return completion
}

// TODO: maybe call this dial?
_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) -> (^Completion, net.Network_Error) {
	if endpoint.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	family := net.family_from_endpoint(endpoint)
	sock, err := net.create_socket(family, .TCP)
	if err != nil {
		return nil, err
	}

	if err = _prepare_socket(sock); err != nil {
		close(io, net.any_socket_to_socket(sock))
		return nil, err
	}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Connect {
		callback = callback,
		socket   = sock.(net.TCP_Socket),
		sockaddr = _endpoint_to_sockaddr(endpoint),
	}

	queue.push_back(&io.completed, completion)
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

	queue.push_back(&io.completed, completion)
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

	queue.push_back(&io.completed, completion)
	return completion
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
) -> ^Completion {
	if _, ok := socket.(net.UDP_Socket); ok {
		assert(endpoint != nil)
	}

	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Send {
		callback = callback,
		socket   = socket,
		buf      = buf,
		endpoint = endpoint,
		all      = all,
		len      = len(buf),
	}

	queue.push_back(&io.completed, completion)
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

	queue.push_back(&io.completed, completion)
	return completion
}

// Runs the callback after the timeout, using the kqueue.
_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.operation = Op_Timeout {
		callback = callback,
		expires  = time.time_add(time.now(), dur),
	}

	append(&io.timeouts, completion)
	return completion
}

