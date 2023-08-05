//+private
//+build windows
package nbio

import "core:c"
import "core:mem"
import "core:net"
import "core:os"
import "core:thread"
import "core:time"
import win "core:sys/windows"

Default :: struct {
	allocator:       mem.Allocator,
	pool:            thread.Pool,
	completion_pool: Pool(Completion),
	pending:         [dynamic]^Completion,
	started:         bool,
}

Completion :: struct {
	df:            ^Default,
	operation:     Operation,
	user_callback: rawptr,
	user_data:     rawptr,
}

_init :: proc(io: ^IO, entries: u32 = DEFAULT_ENTRIES, _: u32 = 0, allocator := context.allocator) -> (err: os.Errno) {
	df := new(Default, allocator)

	df.allocator = allocator
	df.pending = make([dynamic]^Completion, allocator)

	pool_init(&df.completion_pool, allocator = allocator)

	thread.pool_init(&df.pool, allocator, int(entries))
	thread.pool_start(&df.pool)

	io.impl_data = df
	return
}

_destroy :: proc(io: ^IO) {
	df := cast(^Default)io.impl_data
	thread.pool_finish(&df.pool)
	thread.pool_destroy(&df.pool)

	delete(df.pending)

	pool_destroy(&df.completion_pool)

	free(df, df.allocator)
}

_tick :: proc(io: ^IO) -> (err: os.Errno) {
	df := cast(^Default)io.impl_data

	// Pop of all tasks that are done so the internal dynamic array doesn't grow infinitely.
	// PERF: ideally the thread pool does not keep track of tasks that are done, we don't care.
	for _ in thread.pool_pop_done(&df.pool) {}

	return
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Network_Error) {
	if res := win.listen(win.SOCKET(socket), i32(backlog)); res == win.SOCKET_ERROR {
		err = net.Listen_Error(win.WSAGetLastError())
	}
	return
}

Op_Accept :: distinct net.TCP_Socket

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	add_completion(io, user, rawptr(callback), Op_Accept(socket), proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Accept)

		client, source, err := net.accept_tcp(net.TCP_Socket(op))
		if err == nil {
			err = prepare(client)
		}

		callback := cast(On_Accept)completion.user_callback
		callback(completion.user_data, client, source, err)
		pool_put(&completion.df.completion_pool, completion)
	})
}

Op_Close :: distinct os.Handle

_close :: proc(io: ^IO, fd: os.Handle, user: rawptr, callback: On_Close) {
	add_completion(io, user, rawptr(callback), Op_Close(fd), proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Close)

		errno := os.close(os.Handle(op))

		callback := cast(On_Close)completion.user_callback
		callback(completion.user_data, errno == os.ERROR_NONE)
		pool_put(&completion.df.completion_pool, completion)
	})
}

Op_Connect :: distinct net.Endpoint

_connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	if endpoint.port == 0 {
		callback(user, {}, net.Dial_Error.Port_Required)
		return
	}

	add_completion(io, user, rawptr(callback), Op_Connect(endpoint), proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		callback := cast(On_Connect)completion.user_callback
		op := completion.operation.(Op_Connect)

		family := net.family_from_endpoint(net.Endpoint(op))
		sock, err := net.create_socket(family, .TCP)
		if err != nil {
			callback(completion.user_data, {}, err)
			pool_put(&completion.df.completion_pool, completion)
			return
		}

		if err := prepare(sock); err != nil {
			callback(completion.user_data, {}, err)
			pool_put(&completion.df.completion_pool, completion)
			return
		}

		socket := sock.(net.TCP_Socket)
		sockaddr := _endpoint_to_sockaddr(net.Endpoint(op))
		res := win.connect(win.SOCKET(socket), &sockaddr, size_of(sockaddr))

		if res < 0 {
			err = net.Dial_Error(win.WSAGetLastError())
		}

		callback(completion.user_data, socket, err)
		pool_put(&completion.df.completion_pool, completion)
	})
}

Op_Read :: struct {
	fd:  os.Handle,
	buf: []byte,
}

_read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	add_completion(io, user, rawptr(callback), Op_Read{fd = fd, buf = buf}, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Read)

		read, err := os.read(os.Handle(op.fd), op.buf)

		callback := cast(On_Read)completion.user_callback
		callback(completion.user_data, read, err)
		pool_put(&completion.df.completion_pool, completion)
	})
}

Op_Recv :: struct {
	socket: net.Any_Socket,
	buf:    []byte,
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	add_completion(io, user, rawptr(callback), Op_Recv{socket = socket, buf = buf}, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Recv)

		received: int
		err: net.Network_Error
		remote_endpoint: net.Endpoint
		switch sock in op.socket {
		case net.TCP_Socket:
			received, err = net.recv_tcp(sock, op.buf)
		case net.UDP_Socket:
			received, remote_endpoint, err = net.recv_udp(sock, op.buf)
		}

		callback := cast(On_Recv)completion.user_callback
		callback(completion.user_data, received, remote_endpoint, err)
		pool_put(&completion.df.completion_pool, completion)
	})
}

Op_Send :: struct {
	socket:   net.Any_Socket,
	buf:      []byte,
	endpoint: Maybe(net.Endpoint),
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
) {
	if _, ok := socket.(net.UDP_Socket); ok {
		assert(endpoint != nil)
	}

	add_completion(
		io,
		user,
		rawptr(callback),
		Op_Send{socket = socket, buf = buf, endpoint = endpoint},
		proc(t: thread.Task) {
			completion := cast(^Completion)t.data
			op := completion.operation.(Op_Send)

			sent: int
			err: net.Network_Error
			switch sock in op.socket {
			case net.TCP_Socket:
				res := win.send(win.SOCKET(sock), raw_data(op.buf), c.int(len(op.buf)), 0)
				if res < 0 {
					err = net.TCP_Send_Error(win.WSAGetLastError())
				} else {
					sent = int(res)
				}

			case net.UDP_Socket:
				toaddr := _endpoint_to_sockaddr(op.endpoint.(net.Endpoint))
				res := win.sendto(win.SOCKET(sock), raw_data(op.buf), c.int(len(op.buf)), 0, &toaddr, size_of(toaddr))
				if res < 0 {
					err = net.UDP_Send_Error(win.WSAGetLastError())
				} else {
					sent = int(res)
				}
			}

			callback := cast(On_Sent)completion.user_callback
			callback(completion.user_data, sent, err)
			pool_put(&completion.df.completion_pool, completion)
		},
	)
}

Op_Write :: struct {
	fd:  os.Handle,
	buf: []byte,
}

_write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	add_completion(io, user, rawptr(callback), Op_Write{fd = fd, buf = buf}, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Write)

		written, err := os.write(os.Handle(op.fd), op.buf)

		callback := cast(On_Write)completion.user_callback
		callback(completion.user_data, written, err)
		pool_put(&completion.df.completion_pool, completion)
	})
}

Op_Timeout :: struct {
	expires: time.Time,
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	op := Op_Timeout {
		expires = time.time_add(time.now(), dur),
	}

	add_completion(io, user, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Timeout)

		diff := time.diff(time.now(), op.expires)
		if (diff > 0) {
			time.sleep(diff)
		}

		callback := cast(On_Timeout)completion.user_callback
		callback(completion.user_data)
		pool_put(&completion.df.completion_pool, completion)
	})
}

add_completion :: proc(io: ^IO, user_data: rawptr, callback: rawptr, op: Operation, task: thread.Task_Proc) {
	df := cast(^Default)io.impl_data
	c := pool_get(&df.completion_pool)
	c.df = df
	c.user_callback = callback
	c.user_data = user_data
	c.operation = op
	thread.pool_add_task(&df.pool, df.allocator, task, c)
}

_endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: win.SOCKADDR_STORAGE_LH) {
	switch a in ep.address {
	case net.IP4_Address:
		(^win.sockaddr_in)(&sockaddr)^ = win.sockaddr_in {
			sin_port   = u16be(win.USHORT(ep.port)),
			sin_addr   = transmute(win.in_addr)a,
			sin_family = u16(win.AF_INET),
		}
		return
	case net.IP6_Address:
		(^win.sockaddr_in6)(&sockaddr)^ = win.sockaddr_in6 {
			sin6_port   = u16be(win.USHORT(ep.port)),
			sin6_addr   = transmute(win.in6_addr)a,
			sin6_family = u16(win.AF_INET6),
		}
		return
	}
	unreachable()
}
