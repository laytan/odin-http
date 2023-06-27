//+build darwin
package kqueue

import "core:testing"
import "core:os"
import "core:net"
import "core:fmt"
import "core:c"
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
			kq:        ^KQueue,
			done:      bool,
			fd:        os.Handle,
			write_buf: [20]byte,
			read_buf:  [20]byte,
			written:   int,
			read:      int,
		}

		kq: KQueue
		init(&kq)
		defer destroy(&kq)

		tctx := Test_Ctx {
			write_buf = [20]byte{
				1,
				2,
				3,
				4,
				5,
				6,
				7,
				8,
				9,
				10,
				11,
				12,
				13,
				14,
				15,
				16,
				17,
				18,
				19,
				20,
			},
			read_buf = [20]byte{},
		}
		tctx.t = t
		tctx.kq = &kq

		path := "test_write_read_close"
		handle, errno := os.open(
			path,
			os.O_RDWR | os.O_CREATE | os.O_TRUNC,
			os.S_IRUSR | os.S_IWUSR | os.S_IRGRP | os.S_IROTH,
		)
		expect(t, errno == os.ERROR_NONE, fmt.tprintf("open file error: %i", errno))
		defer os.remove(path)

		tctx.fd = handle

		write(&kq, Op_Write{handle, tctx.write_buf[:], 0}, &tctx, write_callback)

		for !tctx.done {
			terr := tick(&kq)
			expect(t, terr == nil, fmt.tprintf("error ticking: %s", terr))
		}

		expect(t, tctx.read == 20)
		expect(t, tctx.written == 20)
		expect(t, slice.equal(tctx.write_buf[:], tctx.read_buf[:]))

		write_callback :: proc(ctx: rawptr, written: int, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("write error: %i", err))

			ctx.written = written

			read(ctx.kq, Op_Read{ctx.fd, ctx.read_buf[:], 0}, ctx, read_callback)
		}

		read_callback :: proc(ctx: rawptr, r: int, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("read error: %i", err))

			ctx.read = r

			close(ctx.kq, ctx.fd, ctx, close_callback)
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
			kq:            ^KQueue,
			send_buf:      []byte,
			recv_buf:      []byte,
			sent:          u32,
			received:      u32,
			accepted_sock: Maybe(os.Socket),
			done:          bool,
		}

		kq: KQueue
		init(&kq)
		defer destroy(&kq)

		tctx := Test_Ctx {
			send_buf = []byte{1, 0, 1, 0, 1, 0, 1, 0, 1, 0},
			recv_buf = []byte{0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		}
		tctx.t = t
		tctx.kq = &kq

		endpoint := net.Endpoint {
			address = net.IP4_Loopback,
			port    = 3131,
		}
		server, err := net.create_socket(.IP4, .TCP)
		expect(t, err == nil, fmt.tprintf("create socket error: %s", err))

		err = net.set_option(server, .Reuse_Address, true)
		expect(t, err == nil, fmt.tprintf("set option error: %s", err))

		err = net.set_blocking(server, false)
		expect(t, err == nil, fmt.tprintf("set non blocking error: %s", err))

		err = net.bind(server, endpoint)
		expect(t, err == nil, fmt.tprintf("bind error: %s", err))

		errn := os.listen(os.Socket(server.(net.TCP_Socket)), 1000)
		expect(t, errn == os.ERROR_NONE, fmt.tprintf("listen error: %i", errn))

		accept(&kq, os.Socket(server.(net.TCP_Socket)), &tctx, accept_callback)

		client, cerr := net.create_socket(.IP4, .TCP)
		expect(t, cerr == nil, fmt.tprintf("create socket error: %s", cerr))

		err = net.set_blocking(client, false)
		expect(t, err == nil, fmt.tprintf("set non blocking error: %s", err))

		sockaddr := os.sockaddr_in {
			sin_port   = u16be(endpoint.port),
			sin_addr   = transmute(os.in_addr)endpoint.address.(net.IP4_Address),
			sin_family = u8(os.AF_INET),
			sin_len    = size_of(os.sockaddr_in),
		}
		ossockaddr := (^os.SOCKADDR)(&sockaddr)
		op_connect := Op_Connect {
			socket = os.Socket(client.(net.TCP_Socket)),
			addr   = ossockaddr,
			len    = i32(ossockaddr.len),
		}
		connect(&kq, op_connect, &tctx, connect_callback)

		for !tctx.done {
			terr := tick(&kq)
			expect(t, terr == nil, fmt.tprintf("tick error: %s", terr))
		}

		expect(
			t,
			len(tctx.send_buf) == int(tctx.sent),
			fmt.tprintf(
				"expected sent to be length of buffer: %i != %i",
				len(tctx.send_buf),
				tctx.sent,
			),
		)
		expect(
			t,
			len(tctx.recv_buf) == int(tctx.received),
			fmt.tprintf(
				"expected recv to be length of buffer: %i != %i",
				len(tctx.recv_buf),
				tctx.received,
			),
		)

		expect(
			t,
			slice.equal(tctx.send_buf[:tctx.received], tctx.recv_buf),
			fmt.tprintf(
				"send and received not the same: %v != %v",
				tctx.send_buf[:tctx.received],
				tctx.recv_buf,
			),
		)

		connect_callback :: proc(ctx: rawptr, sock: os.Socket, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("connect error: %i", err))

			send(ctx.kq, Op_Send{sock, ctx.send_buf, 0}, ctx, send_callback)
		}

		send_callback :: proc(ctx: rawptr, res: u32, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("send error: %i", err))

			ctx.sent = res
		}

		accept_callback :: proc(
			ctx: rawptr,
			sock: os.Socket,
			addr: os.SOCKADDR_STORAGE_LH,
			addr_len: c.int,
			err: os.Errno,
		) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("accept error: %i", err))

			ctx.accepted_sock = sock

			recv(ctx.kq, Op_Recv{sock, ctx.recv_buf, 0}, ctx, recv_callback)
		}

		recv_callback :: proc(ctx: rawptr, buf: []byte, received: u32, err: os.Errno) {
			ctx := cast(^Test_Ctx)ctx
			expect(ctx.t, err == os.ERROR_NONE, fmt.tprintf("recv error: %i", err))

			ctx.received = received
			ctx.done = true
		}
	}
}
