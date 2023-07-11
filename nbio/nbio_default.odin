//+private
//+build !linux !darwin
package nbio

import "core:os"
import "core:thread"
import "core:mem"
import "core:c"
import "core:net"
import "core:time"

_prepare_socket :: proc(socket: net.Any_Socket) -> net.Network_Error {
	return net.set_blocking(socket, true)
}

Default :: struct {
	allocator: mem.Allocator,
	pool:      thread.Pool,
	pending:   [dynamic]^Completion,
	started:   bool,
}

Completion :: struct {
	df:            ^Default,
	operation:     Operation,
	user_callback: rawptr,
	user_data:     rawptr,
}

_init :: proc(
	io: ^IO,
	entries: u32 = DEFAULT_ENTRIES,
	flags: u32 = 0,
	allocator := context.allocator,
) -> (
	err: os.Errno,
) {
	df := new(Default, allocator)
	df.allocator = allocator
	thread.pool_init(&df.pool, allocator, int(entries))
	df.pending = make([dynamic]^Completion, allocator)
	io.impl_data = df
	return
}

_destroy :: proc(io: ^IO) {
	df := cast(^Default)io.impl_data
	thread.pool_finish(&df.pool)
	thread.pool_destroy(&df.pool)

	for c in &df.pending do free(c, df.allocator)
	delete(df.pending)

	free(df, df.allocator)
}

_tick :: proc(io: ^IO) -> (err: os.Errno) {
	df := cast(^Default)io.impl_data
	if !df.started {
		thread.pool_start(&df.pool)
	}
	return
}

_accept :: proc(io: ^IO, socket: os.Socket, user_data: rawptr, callback: Accept_Callback) {
	add_completion(io, user_data, rawptr(callback), Op_Accept{socket = socket}, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Accept)

		sockaddr: os.SOCKADDR_STORAGE_LH
		sockaddrlen := c.int(size_of(sockaddr))

		sock, err := os.accept(op.socket, cast(^os.SOCKADDR)&sockaddr, &sockaddrlen)

		callback := cast(Accept_Callback)completion.user_callback
		callback(completion.user_data, sock, sockaddr, sockaddrlen, err)

		free(completion, completion.df.allocator)
	})
}

_close :: proc(io: ^IO, fd: os.Handle, user_data: rawptr, callback: Close_Callback) {
	add_completion(io, user_data, rawptr(callback), Op_Close{fd}, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Close)

		ok := os.close(op.fd)

		callback := cast(Close_Callback)completion.user_callback
		callback(completion.user_data, ok)

		free(completion, completion.df.allocator)
	})
}

_connect :: proc(io: ^IO, op: Op_Connect, user_data: rawptr, callback: Connect_Callback) {
	add_completion(io, user_data, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Connect)

		err := os.connect(op.socket, op.addr, op.len)

		callback := cast(Connect_Callback)completion.user_callback
		callback(completion.user_data, op.socket, err)

		free(completion, completion.df.allocator)
	})
}

_read :: proc(io: ^IO, op: Op_Read, user_data: rawptr, callback: Read_Callback) {
	add_completion(io, user_data, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Read)

		read, err := os.read_at(op.fd, op.buf, op.offset)

		callback := cast(Read_Callback)completion.user_callback
		callback(completion.user_data, read, err)

		free(completion, completion.df.allocator)
	})
}

_recv :: proc(io: ^IO, op: Op_Recv, user_data: rawptr, callback: Recv_Callback) {
	add_completion(io, user_data, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Recv)

		received, err := os.recv(op.socket, op.buf, op.flags)

		callback := cast(Recv_Callback)completion.user_callback
		callback(completion.user_data, op.buf, received, err)

		free(completion, completion.df.allocator)
	})
}

_send :: proc(io: ^IO, op: Op_Send, user_data: rawptr, callback: Send_Callback) {
	add_completion(io, user_data, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Send)

		sent, err := os.send(op.socket, op.buf, op.flags)

		callback := cast(Send_Callback)completion.user_callback
		callback(completion.user_data, sent, err)

		free(completion, completion.df.allocator)
	})
}

_write :: proc(io: ^IO, op: Op_Write, user_data: rawptr, callback: Write_Callback) {
	add_completion(io, user_data, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Write)

		read, err := os.write_at(op.fd, op.buf, op.offset)

		callback := cast(Write_Callback)completion.user_callback
		callback(completion.user_data, read, err)

		free(completion, completion.df.allocator)
	})
}

_timeout :: proc(io: ^IO, dur: time.Duration, user_data: rawptr, callback: Timeout_Callback) {
	op := Op_Timeout {
		expires = time.time_add(time.now(), dur),
	}

	add_completion(io, user_data, rawptr(callback), op, proc(t: thread.Task) {
		completion := cast(^Completion)t.data
		op := completion.operation.(Op_Timeout)

		diff := time.diff(time.now(), op.expires)
		if (diff > 0) {
			time.sleep(diff)
		}

		callback := cast(Timeout_Callback)completion.user_callback
		callback(completion.user_data)

		free(completion, completion.df.allocator)
	})
}

@(private = "file")
add_completion :: proc(io: ^IO, user_data: rawptr, callback: rawptr, op: Operation, task: thread.Task_Proc) {
	df := cast(^Default)io.impl_data
	c := new(Completion, df.allocator)
	c.df = df
	c.user_callback = callback
	c.user_data = user_data
	c.operation = op
	thread.pool_add_task(&df.pool, df.allocator, task, c)
}
