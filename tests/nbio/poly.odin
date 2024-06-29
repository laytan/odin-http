package tests_nbio

import "core:net"
import "core:os"
import "core:testing"

import "../../nbio"

ev :: testing.expect_value
e  :: testing.expect

// Tests that all poly variants are correctly passing through arguments, and that
// all procs eventually get their callback called.
@(test)
all_poly_work :: proc(tt: ^testing.T) {
	@static io: nbio.IO
	ev(tt, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	@static t: ^testing.T
	t = tt

	@static n: int
	n = 0

	nbio.timeout(&io, 0, 1, proc(one: int) {
		ev(t, one, 1)
	})
	nbio.timeout(&io, 0, 1, 2, proc(one: int, two: int) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.timeout(&io, 0, 1, 2, 3, proc(one: int, two: int, three: int) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	nbio.close(&io, os.INVALID_HANDLE, 1, proc(one: int, ok: bool) {
		ev(t, one, 1)
		ev(t, ok, false)
	})
	nbio.close(&io, os.INVALID_HANDLE, 1, 2, proc(one: int, two: int, ok: bool) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, ok, false)
	})
	nbio.close(&io, os.INVALID_HANDLE, 1, 2, 3, proc(one: int, two: int, three: int, ok: bool) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		ev(t, ok, false)
	})

	nbio.accept(&io, 0, 1, proc(one: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	})
	nbio.accept(&io, 0, 1, 2, proc(one: int, two: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	})
	nbio.accept(&io, 0, 1, 2, 3, proc(one: int, two: int, three: int, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	})

	nbio.connect(&io, {net.IP4_Address{127, 0, 0, 1}, 80}, 1, proc(one: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		nbio.close(&io, socket)
	})
	nbio.connect(&io, {net.IP4_Address{127, 0, 0, 1}, 80}, 1, 2, proc(one: int, two: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		nbio.close(&io, socket)
	})
	nbio.connect(&io, {net.IP4_Address{127, 0, 0, 1}, 80}, 1, 2, 3, proc(one: int, two: int, three: int, socket: net.TCP_Socket, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		nbio.close(&io, socket)
	})

	on_recv1 :: proc(one: int, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ev(t, one, 1)
	}
	on_recv2 :: proc(one: int, two: int, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_recv3 :: proc(one: int, two: int, three: int, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.recv(&io, net.TCP_Socket(0), nil, 1, on_recv1)
	nbio.recv(&io, net.TCP_Socket(0), nil, 1, 2, on_recv2)
	nbio.recv(&io, net.TCP_Socket(0), nil, 1, 2, 3, on_recv3)

	nbio.recv_all(&io, net.TCP_Socket(0), nil, 1, on_recv1)
	nbio.recv_all(&io, net.TCP_Socket(0), nil, 1, 2, on_recv2)
	nbio.recv_all(&io, net.TCP_Socket(0), nil, 1, 2, 3, on_recv3)

	on_send1 :: proc(one: int, sent: int, err: net.Network_Error) {
		ev(t, one, 1)
		e(t, err != nil)
	}
	on_send2 :: proc(one: int, two: int, sent: int, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		e(t, err != nil)
	}
	on_send3 :: proc(one: int, two: int, three: int, sent: int, err: net.Network_Error) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		e(t, err != nil)
	}

	nbio.send(&io, 0, nil, 1, on_send1)
	nbio.send(&io, 0, nil, 1, 2, on_send2)
	nbio.send(&io, 0, nil, 1, 2, 3, on_send3)

	nbio.send(&io, net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, on_send1)
	nbio.send(&io, net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, on_send2)
	nbio.send(&io, net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, 3, on_send3)

	nbio.send_all(&io, 0, nil, 1, on_send1)
	nbio.send_all(&io, 0, nil, 1, 2, on_send2)
	nbio.send_all(&io, 0, nil, 1, 2, 3, on_send3)

	nbio.send_all(&io, net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, on_send1)
	nbio.send_all(&io, net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, on_send2)
	nbio.send_all(&io, net.Endpoint{net.IP4_Address{127, 0, 0, 1}, 80}, 0, nil, 1, 2, 3, on_send3)

	on_read1 :: proc(one: int, read: int, err: os.Errno) {
		ev(t, one, 1)
	}
	on_read2 :: proc(one: int, two: int, read: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_read3 :: proc(one: int, two: int, three: int, read: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.read(&io, os.INVALID_HANDLE, nil, 1, on_read1)
	nbio.read(&io, os.INVALID_HANDLE, nil, 1, 2, on_read2)
	nbio.read(&io, os.INVALID_HANDLE, nil, 1, 2, 3, on_read3)

	nbio.read_all(&io, os.INVALID_HANDLE, nil, 1, on_read1)
	nbio.read_all(&io, os.INVALID_HANDLE, nil, 1, 2, on_read2)
	nbio.read_all(&io, os.INVALID_HANDLE, nil, 1, 2, 3, on_read3)

	nbio.read_at(&io, os.INVALID_HANDLE, 0, nil, 1, on_read1)
	nbio.read_at(&io, os.INVALID_HANDLE, 0, nil, 1, 2, on_read2)
	nbio.read_at(&io, os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_read3)

	nbio.read_at_all(&io, os.INVALID_HANDLE, 0, nil, 1, on_read1)
	nbio.read_at_all(&io, os.INVALID_HANDLE, 0, nil, 1, 2, on_read2)
	nbio.read_at_all(&io, os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_read3)

	on_write1 :: proc(one: int, written: int, err: os.Errno) {
		ev(t, one, 1)
	}
	on_write2 :: proc(one: int, two: int, written: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
	}
	on_write3 :: proc(one: int, two: int, three: int, written: int, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	}

	nbio.write(&io, os.INVALID_HANDLE, nil, 1, on_write1)
	nbio.write(&io, os.INVALID_HANDLE, nil, 1, 2, on_write2)
	nbio.write(&io, os.INVALID_HANDLE, nil, 1, 2, 3, on_write3)

	nbio.write_all(&io, os.INVALID_HANDLE, nil, 1, on_write1)
	nbio.write_all(&io, os.INVALID_HANDLE, nil, 1, 2, on_write2)
	nbio.write_all(&io, os.INVALID_HANDLE, nil, 1, 2, 3, on_write3)

	nbio.write_at(&io, os.INVALID_HANDLE, 0, nil, 1, on_write1)
	nbio.write_at(&io, os.INVALID_HANDLE, 0, nil, 1, 2, on_write2)
	nbio.write_at(&io, os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_write3)

	nbio.write_at_all(&io, os.INVALID_HANDLE, 0, nil, 1, on_write1)
	nbio.write_at_all(&io, os.INVALID_HANDLE, 0, nil, 1, 2, on_write2)
	nbio.write_at_all(&io, os.INVALID_HANDLE, 0, nil, 1, 2, 3, on_write3)

	nbio.next_tick(&io, 1, proc(one: int) {
		ev(t, one, 1)
	})
	nbio.next_tick(&io, 1, 2, proc(one: int, two: int) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.next_tick(&io, 1, 2, 3, proc(one: int, two: int, three: int) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	nbio.poll(&io, os.INVALID_HANDLE, .Read, false, 1, proc(one: int, event: nbio.Poll_Event) {
		ev(t, one, 1)
	})
	nbio.poll(&io, os.INVALID_HANDLE, .Read, false, 1, 2, proc(one: int, two: int, event: nbio.Poll_Event) {
		ev(t, one, 1)
		ev(t, two, 2)
	})
	nbio.poll(&io, os.INVALID_HANDLE, .Read, false, 1, 2, 3, proc(one: int, two: int, three: int, event: nbio.Poll_Event) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)
}

@(test)
read_entire_file_works :: proc(tt: ^testing.T) {
	io: nbio.IO
	ev(tt, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	@static t: ^testing.T
	t = tt

	fd, errno := nbio.open(&io, #file)
	ev(t, errno, os.ERROR_NONE)

	nbio.read_entire_file(&io, fd, 1, proc(one: int, buf: []byte, err: os.Errno) {
		ev(t, one, 1)
		ev(t, err, os.ERROR_NONE)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	nbio.read_entire_file(&io, fd, 1, 2, proc(one: int, two: int, buf: []byte, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, err, os.ERROR_NONE)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	nbio.read_entire_file(&io, fd, 1, 2, 3, proc(one: int, two: int, three: int, buf: []byte, err: os.Errno) {
		ev(t, one, 1)
		ev(t, two, 2)
		ev(t, three, 3)
		ev(t, err, os.ERROR_NONE)
		ev(t, string(buf), #load(#file, string))
		delete(buf)
	})

	ev(t, nbio.run(&io), os.ERROR_NONE)

	nbio.close(&io, fd)

	ev(t, nbio.run(&io), os.ERROR_NONE)
}
