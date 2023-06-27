//+build darwin
//+private
package http

import "core:net"
import "core:os"
import "core:c"
import "core:bufio"
import "core:intrinsics"
import "core:log"
import "core:mem"
import "core:time"

import "kqueue"

Darwin_Server :: struct {
	kq: ^kqueue.KQueue,
}

_server_serve :: proc(server: ^Server) -> (err: net.Network_Error) {
	net.set_blocking(server.tcp_sock, false) or_return

	kq: kqueue.KQueue
	kqueue.init(&kq)
	defer kqueue.destroy(&kq)

	dw_server: Darwin_Server
	dw_server.kq = &kq
	server.impl_data = &dw_server

	log.debug("accepting connections")
	kqueue.accept(&kq, os.Socket(server.tcp_sock), server, on_accept)

	log.debug("starting event loop")
	for {
		if server.shutting_down {
			time.sleep(SHUTDOWN_INTERVAL)
			continue
		}

		if server.shut_down do break

		kqueue.tick(&kq)
	}

	log.debug("event loop end")

	return nil
}

_server_shutdown :: proc(s: ^Server) {
	dw := cast(^Darwin_Server)s.impl_data
	kqueue.destroy(dw.kq)
}

_server_on_conn_close :: proc(server: ^Server, conn: ^Connection) {
	if conn.impl_data != nil {
		inflight := cast(^Darwin_Response_Inflight)conn.impl_data
		free(inflight, inflight.allocator)
	}
}

Darwin_Response_Inflight :: struct {
	c:          ^Connection,
	buf:        []byte,
	sent:       int,
	callback:   Send_Response_Callback,
	will_close: ^bool,
	allocator:  mem.Allocator,
}

_send_response :: proc(
	c: ^Connection,
	buf: []byte,
	will_close: ^bool,
	callback: Send_Response_Callback,
	allocator := context.allocator,
) {
	dw := cast(^Darwin_Server)c.server.impl_data

	inflight := new(Darwin_Response_Inflight, allocator)
	c.impl_data = inflight // So connection_close can free an in progress response.

	inflight.c = c
	inflight.buf = buf
	inflight.callback = callback
	inflight.allocator = allocator
	inflight.will_close = will_close

	log.debug("sending using kqueue")
	kqueue.send(dw.kq, kqueue.Op_Send{os.Socket(c.socket), buf, 0}, inflight, on_send)
}

on_send :: proc(inflight: rawptr, sent: u32, err: os.Errno) {
	inflight := cast(^Darwin_Response_Inflight)inflight
	dw := cast(^Darwin_Server)inflight.c.server.impl_data

	if err != os.ERROR_NONE {
		inflight.c.impl_data = nil
		free(inflight)
		inflight.callback(
			inflight.c,
			inflight.will_close,
			net.TCP_Send_Error(err),
			inflight.allocator,
		)
		return
	}

	inflight.sent += int(sent)
	if len(inflight.buf) == int(sent) {
		inflight.c.impl_data = nil
		free(inflight)
		inflight.callback(inflight.c, inflight.will_close, nil, inflight.allocator)
		return
	}

	log.debug("further sending using kqueue")
	kqueue.send(
		dw.kq,
		kqueue.Op_Send{os.Socket(inflight.c.socket), inflight.buf[inflight.sent:], 0},
		inflight,
		on_send,
	)
}

on_accept :: proc(
	server: rawptr,
	sock: os.Socket,
	addr: os.SOCKADDR_STORAGE_LH,
	addr_len: c.int,
	err: os.Errno,
) {
	server := cast(^Server)server
	dw_server := cast(^Darwin_Server)server.impl_data
	addr := addr

	kqueue.accept(dw_server.kq, os.Socket(server.tcp_sock), server, on_accept)

	ep := sockaddr_to_endpoint(&addr)
	client := net.TCP_Socket(sock)

	c := new(Connection, server.conn_allocator)
	c.state = .New
	c.server = server
	c.client = ep
	c.socket = client

	server.conns[c.socket] = c

	log.errorf("new connection with %v, got %d conns", ep, len(server.conns))
	conn_handle_reqs(c)
}

_scanner_read :: proc(s: ^Scanner, buf: []byte) {
	dw := cast(^Darwin_Server)s.connection.server.impl_data
	kqueue.recv(dw.kq, kqueue.Op_Recv{os.Socket(s.connection.socket), buf, 0}, s, _scanner_on_read)
}

_scanner_on_read :: proc(s: rawptr, _: []byte, n: u32, err: os.Errno) {
	s := cast(^Scanner)s

	// Basically all errors from recv are for exceptional cases and don't happen under normal circumstances.
	e: bufio.Scanner_Error
	if err != os.ERROR_NONE {
		log.errorf("Unexpected recv error from kqueue: %i", err)
		e = .Unknown
	}

	scanner_on_read(s, int(n), e)
}

// Private proc in net package copied verbatim.
sockaddr_to_endpoint :: proc(native_addr: ^os.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
	switch native_addr.family {
	case u8(os.AF_INET):
		addr := cast(^os.sockaddr_in)native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte)addr.sin_addr),
			port    = port,
		}
	case u8(os.AF_INET6):
		addr := cast(^os.sockaddr_in6)native_addr
		port := int(addr.sin6_port)
		ep = net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be)addr.sin6_addr),
			port    = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
}
