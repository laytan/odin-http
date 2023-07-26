package nbio

import "core:testing"
import "core:os"
import "core:net"
import "core:fmt"
import "core:slice"
import "core:mem"

expect :: testing.expect
log :: testing.log

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
		handle, errno := os.open(
			path,
			os.O_RDWR | os.O_CREATE | os.O_TRUNC,
			os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH,
		)
		expect(t, errno == os.ERROR_NONE, fmt.tprintf("open file error: %i", errno))
		defer os.remove(path)

		expect(t, prepare_handle(handle) == nil, "prepare_handle failed")

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

			read(ctx.io, ctx.fd, ctx.read_buf[:], ctx, read_callback)
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

		server, err := net.create_socket(.IP4, .TCP)
		expect(t, err == nil, fmt.tprintf("create socket error: %s", err))

		err = prepare_socket(server)
		expect(t, err == nil, fmt.tprintf("prepare socket err: %s", err))

		err = net.bind(server, endpoint)
		expect(t, err == nil, fmt.tprintf("bind error: %s", err))

		errn := os.listen(os.Socket(server.(net.TCP_Socket)), 1000)
		expect(t, errn == os.ERROR_NONE, fmt.tprintf("listen error: %i", errn))

		accept(&io, server.(net.TCP_Socket), &tctx, accept_callback)

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

		recv_callback :: proc(ctx: rawptr, received: int, _: net.Endpoint, err: net.Network_Error) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == nil, fmt.tprintf("recv error: %i", err))

			ctx.received = received
			ctx.done = true
		}
	}
}
