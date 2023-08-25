package nbio

import "core:fmt"
import "core:mem"
import "core:net"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

expect :: testing.expect
log :: testing.log

@(test)
test_timeout :: proc(t: ^testing.T) {
	io: IO

	ierr := init(&io)
	expect(t, ierr == os.ERROR_NONE, fmt.tprintf("nbio.init error: %v", ierr))

	defer destroy(&io)

	timeout_fired: bool

	timeout(&io, time.Millisecond * 20, &timeout_fired, proc(t_: rawptr) {
		timeout_fired := cast(^bool)t_
		timeout_fired^ = true
	})

	start := time.now()
	for {
		terr := tick(&io)
		expect(t, terr == os.ERROR_NONE, fmt.tprintf("nbio.tick error: %v", terr))

		// TODO: make this more accurate for linux and darwin, windows is accurate.
		if time.since(start) > time.Millisecond * 30 {
			expect(t, timeout_fired, "timeout did not run in time")
			break
		}
	}
}

@(test)
test_write_read_close_wait :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
		}

		for bad_free in track.bad_free_array {
			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
		}
	}

	{
		Test_Ctx :: struct {
			fd:        os.Handle,
			write_buf: [20]byte,
			read_buf:  [20]byte,
			written:   int,
			read:      int,
		}

		io: IO
		init(&io)
		defer destroy(&io)

		tctx := Test_Ctx {
			write_buf = [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20},
			read_buf = [20]byte{},
		}

		path := "test_write_read_close_wait"
		handle, errno := open(
			&io,
			path,
			os.O_RDWR | os.O_CREATE | os.O_TRUNC,
			os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH when ODIN_OS != .Windows else 0,
		)
		expect(t, errno == os.ERROR_NONE, fmt.tprintf("open file error: %i", errno))
		defer os.remove(path)

		tctx.fd = handle

		tctx.written, errno = write_and_wait(&io, handle, tctx.write_buf[:])
		expect(t, errno == os.ERROR_NONE, fmt.tprintf("write error: %i", errno))

		tctx.read, errno = read_at_and_wait(&io, tctx.fd, 0, tctx.read_buf[:])
		expect(t, errno == os.ERROR_NONE, fmt.tprintf("read error: %i", errno))

		ok := close_and_wait(&io, tctx.fd)
		expect(t, ok, "close error")

		expect(t, tctx.read == 20, "expected to have read 20 bytes")
		expect(t, tctx.written == 20, "expected to have written 20 bytes")
		expect(t, slice.equal(tctx.write_buf[:], tctx.read_buf[:]))
	}
}

@(test)
test_write_read_close :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
		}

		for bad_free in track.bad_free_array {
			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
		}
	}

	{
		Test_Ctx :: struct {
			t:         ^testing.T,
			io:        ^IO,
			done:      bool,
			fd:        os.Handle,
			write_buf: [20]byte,
			read_buf:  [20]byte,
			written:   int,
			read:      int,
		}

		io: IO
		init(&io)
		defer destroy(&io)

		tctx := Test_Ctx {
			write_buf = [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20},
			read_buf = [20]byte{},
		}
		tctx.t = t
		tctx.io = &io

		path := "test_write_read_close"
		handle, errno := open(
			&io,
			path,
			os.O_RDWR | os.O_CREATE | os.O_TRUNC,
			os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH when ODIN_OS != .Windows else 0,
		)
		expect(t, errno == os.ERROR_NONE, fmt.tprintf("open file error: %i", errno))
		defer os.close(handle)
		defer os.remove(path)

		tctx.fd = handle

		write(&io, handle, tctx.write_buf[:], &tctx, write_callback)

		for !tctx.done {
			terr := tick(&io)
			expect(t, terr == os.ERROR_NONE, fmt.tprintf("error ticking: %v", terr))
		}

		expect(t, tctx.read == 20, "expected to have read 20 bytes")
		expect(t, tctx.written == 20, "expected to have written 20 bytes")
		expect(t, slice.equal(tctx.write_buf[:], tctx.read_buf[:]))

		write_callback :: proc(ctx: rawptr, written: int, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("write error: %i", err))

			ctx.written = written

			read_at(ctx.io, ctx.fd, 0, ctx.read_buf[:], ctx, read_callback)
		}

		read_callback :: proc(ctx: rawptr, r: int, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("read error: %i", err))

			ctx.read = r

			close(ctx.io, ctx.fd, ctx, close_callback)
		}

		close_callback :: proc(ctx: rawptr, ok: bool) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, ok, "close error")

			ctx.done = true
		}
	}
}

@(test)
test_client_and_server_send_recv :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
		}

		for bad_free in track.bad_free_array {
			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
		}
	}

	{
		Test_Ctx :: struct {
			t:             ^testing.T,
			io:            ^IO,
			send_buf:      []byte,
			recv_buf:      []byte,
			sent:          int,
			received:      int,
			accepted_sock: Maybe(net.TCP_Socket),
			done:          bool,
		}

		io: IO
		init(&io)
		defer destroy(&io)

		tctx := Test_Ctx {
			send_buf = []byte{1, 0, 1, 0, 1, 0, 1, 0, 1, 0},
			recv_buf = []byte{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		}
		tctx.t = t
		tctx.io = &io

		endpoint := net.Endpoint {
			address = net.IP4_Loopback,
			port    = 3131,
		}

		server, err := open_and_listen_tcp(&io, endpoint)
		expect(t, err == nil, fmt.tprintf("create socket error: %s", err))

		accept(&io, server, &tctx, accept_callback)

		connect(&io, endpoint, &tctx, connect_callback)

		for !tctx.done {
			terr := tick(&io)
			expect(t, terr == os.ERROR_NONE, fmt.tprintf("tick error: %v", terr))
		}

		expect(
			t,
			len(tctx.send_buf) == int(tctx.sent),
			fmt.tprintf("expected sent to be length of buffer: %i != %i", len(tctx.send_buf), tctx.sent),
		)
		expect(
			t,
			len(tctx.recv_buf) == int(tctx.received),
			fmt.tprintf("expected recv to be length of buffer: %i != %i", len(tctx.recv_buf), tctx.received),
		)

		expect(
			t,
			slice.equal(tctx.send_buf[:tctx.received], tctx.recv_buf),
			fmt.tprintf("send and received not the same: %v != %v", tctx.send_buf[:tctx.received], tctx.recv_buf),
		)

		connect_callback :: proc(ctx: rawptr, sock: net.TCP_Socket, err: net.Network_Error) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == nil, fmt.tprintf("connect error: %i", err))

			send(ctx.io, sock, ctx.send_buf, ctx, send_callback)
		}

		send_callback :: proc(ctx: rawptr, res: int, err: net.Network_Error) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == nil, fmt.tprintf("send error: %i", err))

			ctx.sent = res
		}

		accept_callback :: proc(ctx: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == nil, fmt.tprintf("accept error: %i", err))

			ctx.accepted_sock = client

			recv(ctx.io, client, ctx.recv_buf, ctx, recv_callback)
		}

		recv_callback :: proc(ctx: rawptr, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == nil, fmt.tprintf("recv error: %i", err))

			ctx.received = received
			ctx.done = true
		}
	}
}

// @(test)
// test_client_and_server_send_recv_wait :: proc(t: ^testing.T) {
// 	track: mem.Tracking_Allocator
// 	mem.tracking_allocator_init(&track, context.allocator)
// 	context.allocator = mem.tracking_allocator(&track)
//
// 	defer {
// 		for _, leak in track.allocation_map {
// 			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
// 		}
//
// 		for bad_free in track.bad_free_array {
// 			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
// 		}
// 	}
//
// 	{
// 		Test_Ctx :: struct {
// 			t:             ^testing.T,
// 			io:            ^IO,
// 			send_buf:      []byte,
// 			recv_buf:      []byte,
// 			sent:          int,
// 			received:      int,
// 			accepted_sock: Maybe(net.TCP_Socket),
// 			done:          bool,
// 		}
//
// 		io: IO
// 		init(&io)
// 		defer destroy(&io)
//
// 		tctx := Test_Ctx {
// 			send_buf = []byte{1, 0, 1, 0, 1, 0, 1, 0, 1, 0},
// 			recv_buf = []byte{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
// 		}
// 		tctx.t = t
// 		tctx.io = &io
//
// 		endpoint := net.Endpoint {
// 			address = net.IP4_Loopback,
// 			port    = 8080,
// 		}
//
// 		server, err := open_and_listen_tcp(&io, endpoint)
// 		expect(t, err == nil, fmt.tprintf("create socket error: %s", err))
//
// 		accept(&io, server, &tctx, accept_callback)
//
// 		connect(&io, endpoint, &tctx, connect_callback)
//
// 		for !tctx.done {
// 			terr := tick(&io)
// 			expect(t, terr == os.ERROR_NONE, fmt.tprintf("tick error: %v", terr))
// 		}
//
// 		expect(
// 			t,
// 			len(tctx.send_buf) == int(tctx.sent),
// 			fmt.tprintf("expected sent to be length of buffer: %i != %i", len(tctx.send_buf), tctx.sent),
// 		)
// 		expect(
// 			t,
// 			len(tctx.recv_buf) == int(tctx.received),
// 			fmt.tprintf("expected recv to be length of buffer: %i != %i", len(tctx.recv_buf), tctx.received),
// 		)
//
// 		expect(
// 			t,
// 			slice.equal(tctx.send_buf[:tctx.received], tctx.recv_buf),
// 			fmt.tprintf("send and received not the same: %v != %v", tctx.send_buf[:tctx.received], tctx.recv_buf),
// 		)
//
// 		connect_callback :: proc(ctx: rawptr, sock: net.TCP_Socket, err: net.Network_Error) {
// 			ctx := cast(^Test_Ctx)ctx
// 			expect(ctx.t, err == nil, fmt.tprintf("connect error: %i", err))
//
// 			res, serr := send_and_wait(ctx.io, sock, ctx.send_buf)
// 			expect(ctx.t, serr == nil, fmt.tprintf("send error: %i", serr))
// 			ctx.sent = res
// 		}
//
// 		accept_callback :: proc(ctx: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
// 			ctx := cast(^Test_Ctx)ctx
// 			expect(ctx.t, err == nil, fmt.tprintf("accept error: %i", err))
//
// 			ctx.accepted_sock = client
//
// 			res, rerr := recv_and_wait(ctx.io, client, ctx.recv_buf)
// 			expect(ctx.t, rerr == nil, fmt.tprintf("recv error: %i", rerr))
// 			ctx.received = res
// 			ctx.done = true
// 		}
// 	}
// }

@(test)
test_relies_on_offset :: proc(t: ^testing.T) {
	io: IO
	init(&io)
	defer destroy(&io)

	path := "test_relies_on_offset"
	handle, errno := open(
		&io,
		path,
		os.O_RDWR | os.O_CREATE | os.O_TRUNC,
		os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH when ODIN_OS != .Windows else 0,
	)
	expect(t, errno == os.ERROR_NONE, fmt.tprintf("open file error: %i", errno))
	defer os.close(handle)
	defer os.remove(path)

	// Write 10 bytes, expect the internal cursor to be 10.
	written, werrno := write_and_wait(&io, handle, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10})
	expect(t, werrno == os.ERROR_NONE, fmt.tprintf("write file error: %i", werrno))

	// Write another 10 bytes, expect the internal cursor to be at the end.
	written, werrno = write_and_wait(&io, handle, {10, 9, 8, 7, 6, 5, 4, 3, 2, 1})
	expect(t, werrno == os.ERROR_NONE, fmt.tprintf("write file error: %i", werrno))

	buf: [20]byte

	// Because the internal cursor is at the end, a read should result nothing.
	read, rerrno := read_and_wait(&io, handle, buf[:])
	expect(t, rerrno == os.ERROR_NONE, fmt.tprintf("read file error: %i", rerrno))
	expect(t, read == 0, fmt.tprintf("we read %i bytes, should be 0 because we are at the end", read))

	// Seek back to the start, internal cursor to 0.
	offset, seek_errorno := os.seek(handle, 0, 0)
	expect(t, seek_errorno == os.ERROR_NONE, fmt.tprintf("seek file error: %i", seek_errorno))
	expect(t, offset == 0, fmt.tprintf("expected new offset to be start, got: %i", offset))

	// Read 5 bytes from the start, advancing the cursor, that would be {1, 2, 3, 4, 5} from the first write.
	read, rerrno = read_and_wait(&io, handle, buf[:5])
	expect(t, rerrno == os.ERROR_NONE, fmt.tprintf("read error: %i", rerrno))
	expect(t, read == 5, fmt.tprintf("expected to have read 5 bytes, got: %i", read))
	expect(t, buf[4] == 5, fmt.tprintf("expected the 4th index in buf to be 5, got %v", buf[4]))

	// Read the next 5 bytes, that would be {6, 7, 8, 9, 10} still from the first write.
	read, rerrno = read_and_wait(&io, handle, buf[5:10])
	expect(t, rerrno == os.ERROR_NONE, fmt.tprintf("read error: %i", rerrno))
	expect(t, read == 5, fmt.tprintf("expected to have read 5 bytes, got: %i", read))
	expect(t, buf[7] == 8, fmt.tprintf("expected the 7th index in buf to be 8, got %v", buf[7]))

	// Explicitly read 5 bytes at offset 5, that would be {5, 6, 7, 8, 9, 10} from the first write.
	read, rerrno = read_at_and_wait(&io, handle, 5, buf[10:15])
	expect(t, rerrno == os.ERROR_NONE, fmt.tprintf("read error: %i", rerrno))
	expect(t, read == 5, fmt.tprintf("expected to have read 5 bytes, got: %i", read))
	expect(t, buf[12] == 8, fmt.tprintf("expected the 12th index in buf to be 8, got %v", buf[12]))
}
