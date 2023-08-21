//+private
//+build windows
package nbio

import "core:c"
import "core:container/queue"
import "core:mem"
import "core:net"
import "core:os"
import "core:runtime"
import "core:time"

import win "core:sys/windows"

foreign import mswsock "system:mswsock.lib"
@(default_calling_convention="stdcall")
foreign mswsock {
	AcceptEx :: proc(
		socket: win.SOCKET,
		accept: win.SOCKET,
		addr_buf: win.PVOID,
		addr_len: win.DWORD,
		local_addr_len: win.DWORD,
		remote_addr_len: win.DWORD,
		bytes_received: win.LPDWORD,
		overlapped: win.LPOVERLAPPED,
	) -> win.BOOL ---
}

FILE_SKIP_COMPLETION_PORT_ON_SUCCESS :: 0x1
FILE_SKIP_SET_EVENT_ON_HANDLE :: 0x2

SO_UPDATE_ACCEPT_CONTEXT :: 28683

WSA_IO_INCOMPLETE :: 996
WSA_IO_PENDING :: 997

WSAID_CONNECTEX :: win.GUID{0x25a207b9, 0xddf3, 0x4660, [8]win.BYTE{0x8e, 0xe9, 0x76, 0xe5, 0x8c, 0x74, 0x06, 0x3e}}
LPFN_CONNECTEX :: #type proc(
	socket: win.SOCKET,
	addr: ^win.SOCKADDR_STORAGE_LH,
	namelen: win.c_int,
	send_buf: win.PVOID,
	send_data_len: win.DWORD,
	bytes_sent: win.LPDWORD,
	overlapped: win.LPOVERLAPPED,
) -> win.BOOL

// TODO: convert windows error to os error.

Windows :: struct {
	iocp:            win.HANDLE,
	allocator:       mem.Allocator,
	timeouts:        [dynamic]^Completion,
	completed:       queue.Queue(^Completion),
	completion_pool: Pool(Completion),
	io_pending:      int,
}

Completion :: struct {
	// NOTE: needs to be the first field.
	over: win.OVERLAPPED,

	op: Operation,
	callback: proc(winio: ^Windows, completion: ^Completion),
	ctx: runtime.Context,
	user_callback: rawptr,
	user_data: rawptr,
}

_init :: proc(io: ^IO, entries: u32 = DEFAULT_ENTRIES, _: u32 = 0, allocator := context.allocator) -> (err: os.Errno) {
	winio := new(Windows, allocator)
	winio.allocator = allocator

	pool_init(&winio.completion_pool, allocator = allocator)
	queue.init(&winio.completed, allocator = allocator)
	winio.timeouts = make([dynamic]^Completion, allocator)

	win.ensure_winsock_initialized()
	defer if err != win.NO_ERROR {
		assert(win.WSACleanup() == win.NO_ERROR)
	}

	winio.iocp = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, nil, 0)
	if winio.iocp == nil {
		err = os.Errno(win.GetLastError())
		return
	}

	io.impl_data = winio
	return
}

_destroy :: proc(io: ^IO) {
	winio := cast(^Windows)io.impl_data

	delete(winio.timeouts)
	queue.destroy(&winio.completed)
	pool_destroy(&winio.completion_pool)

	win.CloseHandle(winio.iocp)
	assert(win.WSACleanup() == win.NO_ERROR)
}

_tick :: proc(io: ^IO) -> (err: os.Errno) {
	winio := cast(^Windows)io.impl_data

	if queue.len(winio.completed) == 0 {
		flush_timeouts(winio)

		if winio.io_pending > 0 {
			events: [64]win.OVERLAPPED_ENTRY
			entries_removed: win.ULONG
			if !win.GetQueuedCompletionStatusEx(winio.iocp, raw_data(events[:]), 64, &entries_removed, 0, false) {
				if terr := win.GetLastError(); terr != win.ERROR_TIMEOUT {
					err = os.Errno(terr)
					return
				}
			}

			assert(winio.io_pending >= int(entries_removed))
			winio.io_pending -= int(entries_removed)

			for event in events[:entries_removed] {
				// This is actually pointing at the Completion.over field, but because it is the first field
				// It is also a valid pointer to the Completion struct.
				completion := cast(^Completion)event.lpOverlapped
				queue.push_back(&winio.completed, completion)
			}
		}
	}

	// Copy completed to not get into an infinite loop when callbacks add to completed again.
	c := winio.completed
	for completion in queue.pop_front_safe(&c) {
		context = completion.ctx
		completion.callback(winio, completion)
	}
	return
}

flush_timeouts :: proc(winio: ^Windows) -> (expires: Maybe(time.Duration)) {
	curr: time.Time
	timeout_len := len(winio.timeouts)
	if timeout_len > 0 do curr = time.now()

	for i := 0; i < timeout_len; {
		completion := winio.timeouts[i]
		cexpires := time.diff(curr, completion.op.(Op_Timeout).expires)

		// Timeout done.
		if (cexpires <= 0) {
			ordered_remove(&winio.timeouts, i)
			queue.push_back(&winio.completed, completion)
			continue
		}

		// Update minimum timeout.
		exp, ok := expires.?
		expires = min(exp, cexpires) if ok else cexpires

		i += 1
	}
	return
}

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Network_Error) {
	if res := win.listen(win.SOCKET(socket), i32(backlog)); res == win.SOCKET_ERROR {
		err = net.Listen_Error(win.WSAGetLastError())
	}
	return
}

submit :: proc(io: ^IO, user: rawptr, callback: rawptr, op: Operation) {
	winio := cast(^Windows)io.impl_data

	completion := pool_get(&winio.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = callback
	completion.op = op

	completion.callback = proc(winio: ^Windows, completion: ^Completion) {
		switch &op in completion.op {
		case Op_Accept:
			source, err := op.callback(winio, completion, &op)
			if err_incomplete(err) do return

			rerr := net.Accept_Error(err)
			if rerr != nil do win.closesocket(op.client)

			cb := cast(On_Accept)completion.user_callback
			cb(completion.user_data, net.TCP_Socket(op.client), source, rerr)

		case Op_Connect:
			err := op.callback(winio, completion, &op)
			if err_incomplete(err) do return

			rerr := net.Dial_Error(err)
			if rerr != nil do win.closesocket(op.socket)

			cb := cast(On_Connect)completion.user_callback
			cb(completion.user_data, net.TCP_Socket(op.socket), rerr)

		case Op_Close:   unimplemented()
		case Op_Read:    unimplemented()
		case Op_Recv:    unimplemented()
		case Op_Send:    unimplemented()
		case Op_Write:   unimplemented()
		case Op_Timeout: unimplemented()
		}
		pool_put(&winio.completion_pool, completion)
	}
	queue.push_back(&winio.completed, completion)
}

Op_Accept :: struct {
	callback: proc(^Windows, ^Completion, ^Op_Accept) -> (source: net.Endpoint, err: win.c_int),
	socket:   win.SOCKET,
	client:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	internal_callback :: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Accept) -> (source: net.Endpoint, err: win.c_int) {
		ok: win.BOOL
		if op.client == win.INVALID_SOCKET {
			op.client, err = open_socket(winio, .IP4, .TCP)
			if err != win.NO_ERROR do return

			bytes_read: win.DWORD
			ok = AcceptEx(
				op.socket,
				op.client,
				&op.addr,
				0,
				size_of(op.addr),
				size_of(op.addr),
				&bytes_read,
				&comp.over,
			)
		} else {
			// Get status update, we've already initiated the accept.
			flags: win.DWORD
			transferred: win.DWORD
			ok = win.WSAGetOverlappedResult(
				op.socket,
				&comp.over,
				&transferred,
				win.FALSE,
				&flags,
			)
		}

		if !ok {
			err = win.WSAGetLastError()
			return

		}

		// enables getsockopt, setsockopt, getsockname, getpeername.
		win.setsockopt(op.client, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)

		source = _sockaddr_to_endpoint(&op.addr)
		return
	}

	submit(io, user, rawptr(callback), Op_Accept{
		callback = internal_callback,
		socket   = win.SOCKET(socket),
		client   = win.INVALID_SOCKET,
	})
}

Op_Connect :: struct {
	callback: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Connect) -> (err: win.c_int),
	socket:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
}

_connect :: proc(io: ^IO, ep: net.Endpoint, user: rawptr, callback: On_Connect) {
	if ep.port == 0 {
		callback(user, {}, net.Dial_Error.Port_Required)
		return
	}

	internal_callback :: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Connect) -> (err: win.c_int) {
		transferred: win.DWORD
		ok: win.BOOL
		if op.socket == win.INVALID_SOCKET {
			op.socket, err = open_socket(winio, .IP4, .TCP)
			if err != win.NO_ERROR do return

			sockaddr := _endpoint_to_sockaddr({net.IP4_Any, 0})
			res := win.bind(op.socket, &sockaddr, size_of(sockaddr))
			if res < 0 do return win.WSAGetLastError()

			connect_ex: LPFN_CONNECTEX
			num_bytes: win.DWORD
			guid := WSAID_CONNECTEX
			res = win.WSAIoctl(
				op.socket,
				win.SIO_GET_EXTENSION_FUNCTION_POINTER,
				&guid,
				size_of(win.GUID),
				&connect_ex,
				size_of(LPFN_CONNECTEX),
				&num_bytes,
				nil,
				nil,
			)
			if res == win.SOCKET_ERROR do return win.WSAGetLastError()

			ok = connect_ex(
				op.socket,
				&op.addr,
				size_of(op.addr),
				nil,
				0,
				&transferred,
				&comp.over,
			)
		} else {
			flags: win.DWORD
			ok = win.WSAGetOverlappedResult(
				op.socket,
				&comp.over,
				&transferred,
				win.FALSE,
				&flags,
			)
		}
		if !ok do return win.WSAGetLastError()

		// enables getsockopt, setsockopt, getsockname, getpeername.
		win.setsockopt(op.socket, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)
		return
	}

	submit(io, user, rawptr(callback), Op_Connect{
		callback = internal_callback,
		addr     = _endpoint_to_sockaddr(ep),
	})
}

Op_Close :: distinct os.Handle

_close :: proc(io: ^IO, fd: os.Handle, user: rawptr, callback: On_Close) {
	unimplemented()
}

Op_Read :: struct {
	fd:  os.Handle,
	buf: []byte,
}

_read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	unimplemented()
}

Op_Recv :: struct {
	socket: net.Any_Socket,
	buf:    []byte,
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	unimplemented()
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
	unimplemented()
}

Op_Write :: struct {
	fd:  os.Handle,
	buf: []byte,
}

_write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	unimplemented()
}

Op_Timeout :: struct {
	expires: time.Time,
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	unimplemented()
}

// TODO: cross platform.
open_socket :: proc(winio: ^Windows, family: net.Address_Family, protocol: net.Socket_Protocol) -> (socket: win.SOCKET, err: win.c_int) {
	c_type, c_protocol, c_family: c.int

	switch family {
	case .IP4:  c_family = win.AF_INET
	case .IP6:  c_family = win.AF_INET6
	case: unreachable()
	}

	switch protocol {
	case .TCP:  c_type = win.SOCK_STREAM; c_protocol = win.IPPROTO_TCP
	case .UDP:  c_type = win.SOCK_DGRAM;  c_protocol = win.IPPROTO_UDP
	case: unreachable()
	}

	flags: win.DWORD
	flags |= win.WSA_FLAG_OVERLAPPED
	flags |= win.WSA_FLAG_NO_HANDLE_INHERIT

	socket = win.WSASocketW(c_family, c_type, c_protocol, nil, 0, flags)
	if socket == win.INVALID_SOCKET {
		err = win.WSAGetLastError()
		return
	}
	defer if err != win.NO_ERROR do win.closesocket(socket)

	handle := win.HANDLE(socket)

	sock_iocp := win.CreateIoCompletionPort(handle, winio.iocp, nil, 0)
	assert(sock_iocp == winio.iocp)

	mode: byte
	mode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	mode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(handle, mode) {
		err = win.c_int(win.GetLastError()) // techincally unsafe u32 -> i32.
		return
	}

	switch protocol {
	case .TCP:
		if perr := prepare(net.TCP_Socket(socket)); perr != nil {
			err = 1 // TODO: Losing the error here!
			return
		}
	case .UDP:
		if perr := prepare(net.UDP_Socket(socket)); perr != nil {
			err = 1 // TODO: Losing the error here!
			return
		}
	}

	return
}

err_incomplete :: proc(err: win.c_int) -> bool {
	return err == win.WSAEWOULDBLOCK ||
	       err == WSA_IO_PENDING ||
		   err == WSA_IO_INCOMPLETE ||
		   err == win.WSAEALREADY
}

// Verbatim copy of private proc in core:net.
_sockaddr_to_endpoint :: proc(native_addr: ^win.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
	switch native_addr.ss_family {
	case u16(win.AF_INET):
		addr := cast(^win.sockaddr_in) native_addr
		port := int(addr.sin_port)
		ep = net.Endpoint {
			address = net.IP4_Address(transmute([4]byte) addr.sin_addr),
			port = port,
		}
	case u16(win.AF_INET6):
		addr := cast(^win.sockaddr_in6) native_addr
		port := int(addr.sin6_port)
		ep = net.Endpoint {
			address = net.IP6_Address(transmute([8]u16be) addr.sin6_addr),
			port = port,
		}
	case:
		panic("native_addr is neither IP4 or IP6 address")
	}
	return
}

// Verbatim copy of private proc in core:net.
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
