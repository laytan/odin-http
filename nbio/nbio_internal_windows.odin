#+private
package nbio

import "base:runtime"

import "core:container/queue"
import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:time"

import win "core:sys/windows"

_IO :: struct {
	iocp:            win.HANDLE,
	allocator:       mem.Allocator,
	timeouts:        [dynamic]^Completion,
	completed:       queue.Queue(^Completion),
	completion_pool: Pool(Completion),
	io_pending:      int,
	// The asynchronous Windows API's don't support reading at the current offset of a file, so we keep track ourselves.
	offsets:         map[os.Handle]u32,
}

_Completion :: struct {
	over: win.OVERLAPPED,
	ctx:  runtime.Context,
	op:   Operation,
}
#assert(offset_of(Completion, over) == 0, "needs to be the first field to work")

Op_Accept :: struct {
	callback: On_Accept,
	socket:   win.SOCKET,
	client:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
	pending:  bool,
}

Op_Connect :: struct {
	callback: On_Connect,
	socket:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
	pending:  bool,
}

Op_Close :: struct {
	callback: On_Close,
	fd:       Closable,
}

Op_Read :: struct {
	callback: On_Read,
	fd:       os.Handle,
	offset:   int,
	buf:      []byte,
	pending:  bool,
	all:      bool,
	read:     int,
	len:      int,
}

Op_Write :: struct {
	callback: On_Write,
	fd:       os.Handle,
	offset:   int,
	buf:      []byte,
	pending:  bool,

	written:  int,
	len:      int,
	all:      bool,
}

Op_Recv :: struct {
	callback: On_Recv,
	socket:   net.Any_Socket,
	buf:      win.WSABUF,
	pending:  bool,
	all:      bool,
	received: int,
	len:      int,
}

Op_Send :: struct {
	callback: On_Sent,
	socket:   net.Any_Socket,
	buf:      win.WSABUF,
	pending:  bool,

	len:      int,
	sent:     int,
	all:      bool,
}

Op_Timeout :: struct {
	callback: On_Timeout,
	expires:  time.Time,
}

Op_Next_Tick :: struct {}

Op_Poll :: struct {}

Op_Poll_Remove :: struct {}

flush_timeouts :: proc(io: ^IO) -> (expires: Maybe(time.Duration)) {
	curr: time.Time
	timeout_len := len(io.timeouts)

	// PERF: could use a faster clock, is getting time since program start fast?
	if timeout_len > 0 { curr = time.now() }

	for i := 0; i < timeout_len; {
		completion := io.timeouts[i]
		op := &completion.op.(Op_Timeout)
		cexpires := time.diff(curr, op.expires)

		// Timeout done.
		if (cexpires <= 0) {
			ordered_remove(&io.timeouts, i)
			queue.push_back(&io.completed, completion)
			timeout_len -= 1
			continue
		}

		// Update minimum timeout.
		exp, ok := expires.?
		expires = min(exp, cexpires) if ok else cexpires

		i += 1
	}
	return
}

prepare_socket :: proc(io: ^IO, socket: net.Any_Socket) -> net.Network_Error {
	net.set_option(socket, .Reuse_Address, true) or_return
	net.set_option(socket, .TCP_Nodelay, true) or_return

	handle := win.HANDLE(uintptr(net.any_socket_to_socket(socket)))

	handle_iocp := win.CreateIoCompletionPort(handle, io.iocp, 0, 0)
	assert(handle_iocp == io.iocp)

	mode: byte
	mode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	mode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(handle, mode) {
		return net._socket_option_error()
	}

	return nil
}

submit :: proc(io: ^IO, user: rawptr, op: Operation) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.ctx = context
	completion.user_data = user
	completion.op = op

	queue.push_back(&io.completed, completion)
	return completion
}

handle_completion :: proc(io: ^IO, completion: ^Completion) {
	switch &op in completion.op {
	case Op_Accept:
		// TODO: we should directly call the accept callback here, no need for it to be on the Op_Acccept struct.
		source, err := accept_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		if err != nil { win.closesocket(op.client) }

		op.callback(completion.user_data, net.TCP_Socket(op.client), source, err)

	case Op_Connect:
		err := connect_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		if err != nil { win.closesocket(op.socket) }

		op.callback(completion.user_data, net.TCP_Socket(op.socket), err)

	case Op_Close:
		op.callback(completion.user_data, close_callback(io, op))

	case Op_Read:
		read, err := read_callback(io, completion, &op)
		if err_incomplete(err) {
			io.io_pending += 1
			return
		}

		if err == win.ERROR_HANDLE_EOF {
			err = win.NO_ERROR
		}

		op.read += int(read)

		if err != win.NO_ERROR {
			op.callback(completion.user_data, op.read, os.Platform_Error(err))
		} else if op.all && op.read < op.len {
			op.buf = op.buf[read:]

			if op.offset >= 0 {
				op.offset += int(read)
			}

			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback(completion.user_data, op.read, os.ERROR_NONE)
		}

	case Op_Write:
		written, err := write_callback(io, completion, &op)
		if err_incomplete(err) {
			io.io_pending += 1
			return
		}

		op.written += int(written)

		oerr := os.Platform_Error(err)
		if oerr != os.ERROR_NONE {
			op.callback(completion.user_data, op.written, oerr)
		} else if op.all && op.written < op.len {
			op.buf = op.buf[written:]

			if op.offset >= 0 {
				op.offset += int(written)
			}

			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback(completion.user_data, op.written, os.ERROR_NONE)
		}

	case Op_Recv:
		received, err := recv_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		op.received += int(received)

		if err != nil {
			op.callback(completion.user_data, op.received, {}, err)
		} else if op.all && op.received < op.len {
			op.buf = win.WSABUF{
				len = op.buf.len - win.ULONG(received),
				buf = (cast([^]byte)op.buf.buf)[received:],
			}
			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback(completion.user_data, op.received, {}, nil)
		}

	case Op_Send:
		sent, err := send_callback(io, completion, &op)
		if wsa_err_incomplete(err) {
			io.io_pending += 1
			return
		}

		op.sent += int(sent)

		if err != nil {
			op.callback(completion.user_data, op.sent, err)
		} else if op.all && op.sent < op.len {
			op.buf = win.WSABUF{
				len = op.buf.len - win.ULONG(sent),
				buf = (cast([^]byte)op.buf.buf)[sent:],
			}
			op.pending = false

			handle_completion(io, completion)
			return
		} else {
			op.callback(completion.user_data, op.sent, nil)
		}

	case Op_Timeout:
		op.callback(completion.user_data)

	case Op_Next_Tick, Op_Poll, Op_Poll_Remove:
		unreachable()

	}
	pool_put(&io.completion_pool, completion)
}

accept_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Accept) -> (source: net.Endpoint, err: net.Network_Error) {
	ok: win.BOOL
	if op.pending {
		// Get status update, we've already initiated the accept.
		flags: win.DWORD
		transferred: win.DWORD
		ok = win.WSAGetOverlappedResult(op.socket, &comp.over, &transferred, win.FALSE, &flags)
	} else {
		op.pending = true

		oclient: net.Any_Socket
		oclient, err = open_socket(io, .IP4, .TCP)

		if err != nil { return }

		op.client = win.SOCKET(net.any_socket_to_socket(oclient))

		accept_ex: LPFN_ACCEPTEX
		load_socket_fn(op.socket, win.WSAID_ACCEPTEX, &accept_ex)

		#assert(size_of(win.SOCKADDR_STORAGE_LH) >= size_of(win.sockaddr_in) + 16)
		bytes_read: win.DWORD
		ok = accept_ex(
			op.socket,
			op.client,
			&op.addr,
			0,
			size_of(win.sockaddr_in) + 16,
			size_of(win.sockaddr_in) + 16,
			&bytes_read,
			&comp.over,
		)
	}

	if !ok {
		err = net._accept_error()
		return
	}

	// enables getsockopt, setsockopt, getsockname, getpeername.
	win.setsockopt(op.client, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)

	source = sockaddr_to_endpoint(&op.addr)
	return
}

connect_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Connect) -> (err: net.Network_Error) {
	transferred: win.DWORD
	ok: win.BOOL
	if op.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(op.socket, &comp.over, &transferred, win.FALSE, &flags)
	} else {
		op.pending = true

		osocket: net.Any_Socket
		osocket, err = open_socket(io, .IP4, .TCP)

		if err != nil { return }

		op.socket = win.SOCKET(net.any_socket_to_socket(osocket))

		sockaddr := endpoint_to_sockaddr({net.IP4_Any, 0})
		res := win.bind(op.socket, &sockaddr, size_of(sockaddr))
		if res < 0 { return net._bind_error() }

		connect_ex: LPFN_CONNECTEX
		load_socket_fn(op.socket, WSAID_CONNECTEX, &connect_ex)
		// TODO: size_of(win.sockaddr_in6) when ip6.
		ok = connect_ex(op.socket, &op.addr, size_of(win.sockaddr_in) + 16, nil, 0, &transferred, &comp.over)
	}
	if !ok { return net._dial_error() }

	// enables getsockopt, setsockopt, getsockname, getpeername.
	win.setsockopt(op.socket, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)
	return
}

close_callback :: proc(io: ^IO, op: Op_Close) -> bool {
	// NOTE: This might cause problems if there is still IO queued/pending.
	// Is that our responsibility to check/keep track of?
	// Might want to call win.CancelloEx to cancel all pending operations first.

	switch h in op.fd {
	case os.Handle:
		delete_key(&io.offsets, h)
		return win.CloseHandle(win.HANDLE(h)) == true
	case net.TCP_Socket:
		return win.closesocket(win.SOCKET(h)) == win.NO_ERROR
	case net.UDP_Socket:
		return win.closesocket(win.SOCKET(h)) == win.NO_ERROR
	case net.Socket:
		return win.closesocket(win.SOCKET(h)) == win.NO_ERROR
	case:
		unreachable()
	}
}

read_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Read) -> (read: win.DWORD, err: win.DWORD) {
	ok: win.BOOL
	if op.pending {
		ok = win.GetOverlappedResult(win.HANDLE(op.fd), &comp.over, &read, win.FALSE)
	} else {
		comp.over.Offset = u32(op.offset) if op.offset >= 0 else io.offsets[op.fd]
		comp.over.OffsetHigh = comp.over.Offset >> 32

		ok = win.ReadFile(win.HANDLE(op.fd), raw_data(op.buf), win.DWORD(len(op.buf)), &read, &comp.over)

		// Not sure if this also happens with correctly set up handles some times.
		if ok { log.info("non-blocking read returned immediately, is the handle set up correctly?") }

		op.pending = true
	}

	if !ok { err = win.GetLastError() }

	// Increment offset if this was not a call with an offset set.
	if op.offset >= 0 {
		io.offsets[op.fd] += read
	}

	return
}

write_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Write) -> (written: win.DWORD, err: win.DWORD) {
	ok: win.BOOL
	if op.pending {
		ok = win.GetOverlappedResult(win.HANDLE(op.fd), &comp.over, &written, win.FALSE)
	} else {
		comp.over.Offset = u32(op.offset) if op.offset >= 0 else io.offsets[op.fd]
		comp.over.OffsetHigh = comp.over.Offset >> 32
		ok = win.WriteFile(win.HANDLE(op.fd), raw_data(op.buf), win.DWORD(len(op.buf)), &written, &comp.over)

		// Not sure if this also happens with correctly set up handles some times.
		if ok { log.debug("non-blocking write returned immediately, is the handle set up correctly?") }

		op.pending = true
	}

	if !ok { err = win.GetLastError() }

	// Increment offset if this was not a call with an offset set.
	if op.offset >= 0 {
		io.offsets[op.fd] += written
	}

	return
}

recv_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Recv) -> (received: win.DWORD, err: net.TCP_Recv_Error) {
	sock := win.SOCKET(net.any_socket_to_socket(op.socket))
	ok: win.BOOL
	if op.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(sock, &comp.over, &received, win.FALSE, &flags)
	} else {
		flags: win.DWORD
		err_code := win.WSARecv(sock, &op.buf, 1, &received, &flags, win.LPWSAOVERLAPPED(&comp.over), nil)
		ok = err_code != win.SOCKET_ERROR
		op.pending = true
	}

	if !ok { err = net._tcp_recv_error() }
	return
}

send_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Send) -> (sent: win.DWORD, err: net.TCP_Send_Error) {
	sock := win.SOCKET(net.any_socket_to_socket(op.socket))
	ok: win.BOOL
	if op.pending {
		flags: win.DWORD
		ok = win.WSAGetOverlappedResult(sock, &comp.over, &sent, win.FALSE, &flags)
	} else {
		err_code := win.WSASend(sock, &op.buf, 1, &sent, 0, win.LPWSAOVERLAPPED(&comp.over), nil)
		ok = err_code != win.SOCKET_ERROR
		op.pending = true
	}

	if !ok { err = net._tcp_send_error() }
	return
}

FILE_SKIP_COMPLETION_PORT_ON_SUCCESS :: 0x1
FILE_SKIP_SET_EVENT_ON_HANDLE :: 0x2

SO_UPDATE_ACCEPT_CONTEXT :: 28683

WSAID_CONNECTEX :: win.GUID{0x25a207b9, 0xddf3, 0x4660, [8]win.BYTE{0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e}}

LPFN_CONNECTEX :: #type proc "stdcall" (
	socket: win.SOCKET,
	addr: ^win.SOCKADDR_STORAGE_LH,
	namelen: win.c_int,
	send_buf: win.PVOID,
	send_data_len: win.DWORD,
	bytes_sent: win.LPDWORD,
	overlapped: win.LPOVERLAPPED,
) -> win.BOOL

LPFN_ACCEPTEX :: #type proc "stdcall" (
	listen_sock: win.SOCKET,
	accept_sock: win.SOCKET,
	addr_buf: win.PVOID,
	addr_len: win.DWORD,
	local_addr_len: win.DWORD,
	remote_addr_len: win.DWORD,
	bytes_received: win.LPDWORD,
	overlapped: win.LPOVERLAPPED,
) -> win.BOOL

wsa_err_incomplete :: proc(err: $T) -> bool {
	when T == net.Dial_Error {
		if err == .Already_Connecting {
			return true
		}
	}

	when T != net.Network_Error {
		if err == .Would_Block {
			return true
		} else if err != .Unknown {
			return false
		}
	}

	last := win.System_Error(net.last_platform_error())
	#partial switch last {
	case .WSAEWOULDBLOCK, .IO_PENDING, .IO_INCOMPLETE, .WSAEALREADY: return true
	case: return false
	}
}

err_incomplete :: proc(err: win.DWORD) -> bool {
	return err == win.ERROR_IO_PENDING
}

// Verbatim copy of private proc in core:net.
sockaddr_to_endpoint :: proc(native_addr: ^win.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
	switch native_addr.ss_family {
	case u16(win.AF_INET):
		addr := cast(^win.sockaddr_in)native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte)addr.sin_addr),
			port    = port,
		}
	case u16(win.AF_INET6):
		addr := cast(^win.sockaddr_in6)native_addr
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

// Verbatim copy of private proc in core:net.
endpoint_to_sockaddr :: proc(ep: net.Endpoint) -> (sockaddr: win.SOCKADDR_STORAGE_LH) {
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

// TODO: loading this takes a overlapped parameter, maybe we can do this async?
load_socket_fn :: proc(subject: win.SOCKET, guid: win.GUID, fn: ^$T) {
	guid := guid
	bytes: u32
	rc := win.WSAIoctl(
		subject,
		win.SIO_GET_EXTENSION_FUNCTION_POINTER,
		&guid,
		size_of(guid),
		fn,
		size_of(fn),
		&bytes,
		nil,
		nil,
	)
	assert(rc != win.SOCKET_ERROR)
	assert(bytes == size_of(fn^))
}
