//+private
//+build windows
package nbio

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
	callback: proc(io: ^IO, completion: ^Completion),
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

	// TODO: error handling.
	win.CloseHandle(winio.iocp)
	// win.WSACleanup()

	free(io.impl_data)
}

_tick :: proc(io: ^IO) -> (err: os.Errno) {
	winio := cast(^Windows)io.impl_data

	if queue.len(winio.completed) == 0 {
		next_timeout := flush_timeouts(winio)

		// Wait a maximum of a ms if there is nothing to do.
		wait_ms: win.DWORD = 1 if winio.io_pending == 0 else 0

		// But, to counter inaccuracies in low timeouts,
		// lets make the call exit immediately if the next timeout is close.
		if nt, ok := next_timeout.?; ok && nt <= time.Millisecond * 15 {
			wait_ms = 0
		}

		events: [64]win.OVERLAPPED_ENTRY
		entries_removed: win.ULONG
		if !win.GetQueuedCompletionStatusEx(
			winio.iocp,
			raw_data(events[:]),
			64,
			&entries_removed,
			wait_ms,
			false,
		) {
			if terr := win.GetLastError(); terr != win.WAIT_TIMEOUT {
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

	// Prevent infinte loop when callback adds to completed by storing length.
	n := queue.len(winio.completed)
	for _ in 0..<n {
		completion := queue.pop_front(&winio.completed)
		context = completion.ctx
		completion.callback(io, completion)
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

_listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Network_Error) {
	if res := win.listen(win.SOCKET(socket), i32(backlog)); res == win.SOCKET_ERROR {
		err = net.Listen_Error(win.WSAGetLastError())
	}
	return
}

// Basically a copy of `os.open`, where a flag is added to signal async io, and creation of IOCP.
// Specifically the FILE_FLAG_OVERLAPPEd flag.
_open :: proc(io: ^IO, path: string, mode, perm: int) -> (os.Handle, os.Errno) {
	if len(path) == 0 {
		return os.INVALID_HANDLE, os.ERROR_FILE_NOT_FOUND
	}

	access: u32
	switch mode & (os.O_RDONLY|os.O_WRONLY|os.O_RDWR) {
	case os.O_RDONLY: access = win.FILE_GENERIC_READ
	case os.O_WRONLY: access = win.FILE_GENERIC_WRITE
	case os.O_RDWR:   access = win.FILE_GENERIC_READ | win.FILE_GENERIC_WRITE
	}

	if mode&os.O_CREATE != 0 {
		access |= win.FILE_GENERIC_WRITE
	}
	if mode&os.O_APPEND != 0 {
		access &~= win.FILE_GENERIC_WRITE
		access |=  win.FILE_APPEND_DATA
	}

	share_mode := win.FILE_SHARE_READ|win.FILE_SHARE_WRITE
	sa: ^win.SECURITY_ATTRIBUTES = nil
	sa_inherit := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = true}
	if mode&os.O_CLOEXEC == 0 {
		sa = &sa_inherit
	}

	create_mode: u32
	switch {
	case mode&(os.O_CREATE|os.O_EXCL) == (os.O_CREATE | os.O_EXCL):
		create_mode = win.CREATE_NEW
	case mode&(os.O_CREATE|os.O_TRUNC) == (os.O_CREATE | os.O_TRUNC):
		create_mode = win.CREATE_ALWAYS
	case mode&os.O_CREATE == os.O_CREATE:
		create_mode = win.OPEN_ALWAYS
	case mode&os.O_TRUNC == os.O_TRUNC:
		create_mode = win.TRUNCATE_EXISTING
	case:
		create_mode = win.OPEN_EXISTING
	}

	flags := win.FILE_ATTRIBUTE_NORMAL|win.FILE_FLAG_BACKUP_SEMANTICS

	// This line is the only thing different from the `os.open` procedure.
	// This makes it an asynchronous file that can be used in nbio.
	flags |= win.FILE_FLAG_OVERLAPPED

	wide_path := win.utf8_to_wstring(path)
	handle := os.Handle(win.CreateFileW(
		wide_path,
		access,
		share_mode,
		sa,
		create_mode,
		flags,
		nil,
	))

	if handle == os.INVALID_HANDLE {
		err := os.Errno(win.GetLastError())
		return os.INVALID_HANDLE, err
	}

	// Everything past here is custom/not from `os.open`.

	winio := cast(^Windows)io.impl_data

	handle_iocp := win.CreateIoCompletionPort(win.HANDLE(handle), winio.iocp, nil, 0)
	assert(handle_iocp == winio.iocp)

	mode: byte
	mode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	mode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(win.HANDLE(handle), mode) {
		win.CloseHandle(win.HANDLE(handle))
		return os.INVALID_HANDLE, os.Errno(win.GetLastError())
	}

	return handle, os.ERROR_NONE
}

_open_socket :: proc(io: ^IO, family: net.Address_Family, protocol: net.Socket_Protocol) -> (socket: net.Any_Socket, err: net.Network_Error) {
	socket, err = net.create_socket(family, protocol)
	if err != nil do return

	err = prepare_socket(io, socket)
	if err != nil do net.close(socket)
	return
}

prepare_socket :: proc(io: ^IO, socket: net.Any_Socket) -> net.Network_Error {
	net.set_option(socket, .Reuse_Address, true) or_return
	net.set_option(socket, .TCP_Nodelay, true)   or_return

	winio := cast(^Windows)io.impl_data

	handle := win.HANDLE(uintptr(net.any_socket_to_socket(socket)))

	handle_iocp := win.CreateIoCompletionPort(handle, winio.iocp, nil, 0)
	assert(handle_iocp == winio.iocp)

	mode: byte
	mode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	mode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(handle, mode) {
		return net.Socket_Option_Error(win.GetLastError())
	}

	return nil
}

submit :: proc(io: ^IO, user: rawptr, callback: rawptr, op: Operation) {
	winio := cast(^Windows)io.impl_data

	completion := pool_get(&winio.completion_pool)
	completion.ctx = context
	completion.user_data = user
	completion.user_callback = callback
	completion.op = op

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		winio := cast(^Windows)io.impl_data

		switch &op in completion.op {
		case Op_Accept:
			source, err := op.callback(io, completion, &op)
			if wsa_err_incomplete(err) {
				winio.io_pending += 1
				return
			}

			rerr := net.Accept_Error(err)
			if rerr != nil do win.closesocket(op.client)

			cb := cast(On_Accept)completion.user_callback
			cb(completion.user_data, net.TCP_Socket(op.client), source, rerr)

		case Op_Connect:
			err := op.callback(io, completion, &op)
			if wsa_err_incomplete(err) {
				winio.io_pending += 1
				return
			}

			rerr := net.Dial_Error(err)
			if rerr != nil do win.closesocket(op.socket)

			cb := cast(On_Connect)completion.user_callback
			cb(completion.user_data, net.TCP_Socket(op.socket), rerr)

		case Op_Close:
			cb := cast(On_Close)completion.user_callback
			cb(completion.user_data, op.callback(winio, op))

		case Op_Read:
			read, err := op.callback(winio, completion, &op)
			if err_incomplete(err) {
				winio.io_pending += 1
				return
			}

			cb := cast(On_Read)completion.user_callback
			cb(completion.user_data, int(read), os.Errno(err))

		case Op_Write:
			written, err := op.callback(winio, completion, &op)
			if err_incomplete(err) {
				winio.io_pending += 1
				return
			}

			cb := cast(On_Write)completion.user_callback
			cb(completion.user_data, int(written), os.Errno(err))

		case Op_Recv:
			received, err := op.callback(winio, completion, &op)
			if wsa_err_incomplete(err) {
				winio.io_pending += 1
				return
			}

			cb := cast(On_Recv)completion.user_callback
			cb(completion.user_data, int(received), {}, net.TCP_Recv_Error(err))

		case Op_Send:
			sent, err := op.callback(winio, completion, &op)
			if wsa_err_incomplete(err) {
				winio.io_pending += 1
				return
			}

			cb := cast(On_Sent)completion.user_callback
			cb(completion.user_data, int(sent), net.TCP_Send_Error(err))

		case Op_Timeout: unreachable()
		}
		pool_put(&winio.completion_pool, completion)
	}
	queue.push_back(&winio.completed, completion)
}

Op_Accept :: struct {
	callback: proc(^IO, ^Completion, ^Op_Accept) -> (source: net.Endpoint, err: win.c_int),
	socket:   win.SOCKET,
	client:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
	pending:  bool,
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	internal_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Accept) -> (source: net.Endpoint, err: win.c_int) {
		ok: win.BOOL
		if op.pending {
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
		} else {
			op.pending = true

			oclient, oerr := open_socket(io, .IP4, .TCP)

			err = win.c_int(net_err_to_code(oerr))
			if err != win.NO_ERROR do return

			op.client = win.SOCKET(net.any_socket_to_socket(oclient))

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
		}

		if !ok {
			err = win.WSAGetLastError()
			return
		}

		// enables getsockopt, setsockopt, getsockname, getpeername.
		win.setsockopt(op.client, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)

		source = sockaddr_to_endpoint(&op.addr)
		return
	}

	submit(io, user, rawptr(callback), Op_Accept{
		callback = internal_callback,
		socket   = win.SOCKET(socket),
		client   = win.INVALID_SOCKET,
	})
}

Op_Connect :: struct {
	callback: proc(^IO, ^Completion, ^Op_Connect) -> (err: win.c_int),
	socket:   win.SOCKET,
	addr:     win.SOCKADDR_STORAGE_LH,
	pending:  bool,
}

_connect :: proc(io: ^IO, ep: net.Endpoint, user: rawptr, callback: On_Connect) {
	if ep.port == 0 {
		callback(user, {}, net.Dial_Error.Port_Required)
		return
	}

	internal_callback :: proc(io: ^IO, comp: ^Completion, op: ^Op_Connect) -> (err: win.c_int) {
		transferred: win.DWORD
		ok: win.BOOL
		if op.pending {
			flags: win.DWORD
			ok = win.WSAGetOverlappedResult(op.socket, &comp.over, &transferred, win.FALSE, &flags)
		} else {
			op.pending = true

			osocket, oerr := open_socket(io, .IP4, .TCP)

			err = win.c_int(net_err_to_code(oerr))
			if err != win.NO_ERROR do return

			op.socket = win.SOCKET(net.any_socket_to_socket(osocket))

			sockaddr := endpoint_to_sockaddr({net.IP4_Any, 0})
			res := win.bind(op.socket, &sockaddr, size_of(sockaddr))
			if res < 0 do return win.WSAGetLastError()

			connect_ex: LPFN_CONNECTEX
			num_bytes: win.DWORD
			guid := WSAID_CONNECTEX
			// TODO: this can also be done asynchronously.
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

			ok = connect_ex(op.socket, &op.addr, size_of(op.addr), nil, 0, &transferred, &comp.over)
		}
		if !ok do return win.WSAGetLastError()

		// enables getsockopt, setsockopt, getsockname, getpeername.
		win.setsockopt(op.socket, win.SOL_SOCKET, SO_UPDATE_ACCEPT_CONTEXT, nil, 0)
		return
	}

	submit(io, user, rawptr(callback), Op_Connect{
		callback = internal_callback,
		addr     = endpoint_to_sockaddr(ep),
	})
}

Op_Close :: struct {
	callback: proc(^Windows, Op_Close) -> bool,
	fd: os.Handle,
}

_close :: proc(io: ^IO, fd: os.Handle, user: rawptr, callback: On_Close) {
	internal_callback :: proc(winio: ^Windows, op: Op_Close) -> bool {
		// NOTE: This might cause problems if there is still IO queued/pending.
		// Is that our responsibility to check/keep track of?
		// Might want to call win.CancelloEx to cancel all pending operations first.

		// Close is used for both file and socket handles, we call a close proc based on what it is.
		if is_socket(op.fd) or_return {
			return win.closesocket(win.SOCKET(op.fd)) == win.NO_ERROR
		} else {
			return win.CloseHandle(win.HANDLE(op.fd)) == true
		}
	}

	submit(io, user, rawptr(callback), Op_Close{
		callback = internal_callback,
		fd       = fd,
	})
}

Op_Read :: struct {
	callback: proc(^Windows, ^Completion, ^Op_Read) -> (read: win.DWORD, err: win.DWORD),
	fd:       os.Handle,
	buf:      []byte,
	pending:  bool,
}

_read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	internal_callback :: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Read) -> (read: win.DWORD, err: win.DWORD) {
		ok: win.BOOL
		if op.pending {
			ok = win.GetOverlappedResult(win.HANDLE(op.fd), &comp.over, &read, win.FALSE)
		} else {
			// TODO: this requires the file to be opened with win.FILE_FLAG_OVERLAPPED.
			ok = win.ReadFile(win.HANDLE(op.fd), raw_data(op.buf), win.DWORD(len(op.buf)), nil, &comp.over)
			assert(!ok)
			op.pending = true
		}

		if !ok do err = win.GetLastError()
		return
	}

	submit(io, user, rawptr(callback), Op_Read{
		callback = internal_callback,
		fd       = fd,
		buf      = buf,
	})
}

Op_Write :: struct {
	callback: proc(^Windows, ^Completion, ^Op_Write) -> (written: win.DWORD, err: win.DWORD),
	fd:       os.Handle,
	buf:      []byte,
	pending:  bool,
}

_write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	internal_callback :: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Write) -> (written: win.DWORD, err: win.DWORD) {
		ok: win.BOOL
		if op.pending {
			ok = win.GetOverlappedResult(win.HANDLE(op.fd), &comp.over, &written, win.FALSE)
		} else {
			// TODO: this requires the file to be opened with win.FILE_FLAG_OVERLAPPED.
			ok = win.WriteFile(win.HANDLE(op.fd), raw_data(op.buf), win.DWORD(len(op.buf)), nil, &comp.over)
			assert(!ok)
			op.pending = true
		}

		if !ok do err = win.GetLastError()
		return
	}

	submit(io, user, rawptr(callback), Op_Write{
		callback = internal_callback,
		fd       = fd,
		buf      = buf,
	})
}

Op_Recv :: struct {
	callback: proc(^Windows, ^Completion, ^Op_Recv) -> (received: win.DWORD, err: win.c_int),
	socket:   net.Any_Socket,
	buf:      win.WSABUF,
	pending:  bool,
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	// TODO: implement UDP.
	if _, ok := socket.(net.UDP_Socket); ok do unimplemented("nbio.recv with UDP sockets is not yet implemented")

	internal_callback :: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Recv) -> (received: win.DWORD, err: win.c_int) {
		sock := win.SOCKET(net.any_socket_to_socket(op.socket))
		ok: win.BOOL
		if op.pending {
			flags: win.DWORD
			ok = win.WSAGetOverlappedResult(sock, &comp.over, &received, win.FALSE, &flags)
		} else {
			flags: win.DWORD
			err_code := win.WSARecv(sock, &op.buf, 1, nil, &flags, win.LPWSAOVERLAPPED(&comp.over), nil)
			assert(err_code == win.SOCKET_ERROR)
		}

		if !ok do err = win.WSAGetLastError()
		return
	}

	submit(io, user, rawptr(callback), Op_Recv{
		callback = internal_callback,
		socket   = socket,
		buf      = win.WSABUF{
			len = win.ULONG(len(buf)),
			buf = raw_data(buf),
		},
	})
}

Op_Send :: struct {
	callback: proc(^Windows, ^Completion, ^Op_Send) -> (sent: win.DWORD, err: win.c_int),
	socket:   net.Any_Socket,
	buf:      win.WSABUF,
	pending:  bool,
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
) {
	// TODO: implement UDP.
	if _, ok := socket.(net.UDP_Socket); ok do unimplemented("nbio.send with UDP sockets is not yet implemented")

	internal_callback :: proc(winio: ^Windows, comp: ^Completion, op: ^Op_Send) -> (sent: win.DWORD, err: win.c_int) {
		sock := win.SOCKET(net.any_socket_to_socket(op.socket))
		ok: win.BOOL
		if op.pending {
			flags: win.DWORD
			ok = win.WSAGetOverlappedResult(sock, &comp.over, &sent, win.FALSE, &flags)
		} else {
			err_code := win.WSASend(sock, &op.buf, 1, nil, 0, win.LPWSAOVERLAPPED(&comp.over), nil)
			assert(err_code == win.SOCKET_ERROR)
		}

		if !ok do err = win.WSAGetLastError()
		return
	}

	submit(io, user, rawptr(callback), Op_Send{
		callback = internal_callback,
		socket   = socket,
		buf      = win.WSABUF{
			len = win.ULONG(len(buf)),
			buf = raw_data(buf),
		},
	})
}

Op_Timeout :: struct {
	expires: time.Time,
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	winio := cast(^Windows)io.impl_data

	completion := pool_get(&winio.completion_pool)

	completion.op = Op_Timeout{time.time_add(time.now(), dur)}
	completion.user_data = user
	completion.user_callback = rawptr(callback)
	completion.ctx = context

	completion.callback = proc(io: ^IO, completion: ^Completion) {
		winio := cast(^Windows)io.impl_data
		context = completion.ctx

		cb := cast(On_Timeout)completion.user_callback
		cb(completion.user_data)

		pool_put(&winio.completion_pool, completion)
	}

	append(&winio.timeouts, completion)
}

wsa_err_incomplete :: proc(err: win.c_int) -> bool {
	return err == win.WSAEWOULDBLOCK  ||
	       err == WSA_IO_PENDING      ||
		   err == WSA_IO_INCOMPLETE   ||
		   err == win.WSAEALREADY
}

err_incomplete :: proc(err: win.DWORD) -> bool {
	return err == win.ERROR_IO_PENDING
}

// Verbatim copy of private proc in core:net.
sockaddr_to_endpoint :: proc(native_addr: ^win.SOCKADDR_STORAGE_LH) -> (ep: net.Endpoint) {
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

is_socket :: proc(fd: os.Handle) -> (is_socket: bool, ok: bool) {
	size: win.c_int = size_of(win.c_int)
	err_code: [size_of(win.c_int)]byte
	if err := win.getsockopt(win.SOCKET(fd), win.SOL_SOCKET, win.SO_ERROR, raw_data(err_code[:]), &size); err != win.NO_ERROR {
		aerr := win.GetLastError()
		if aerr == win.WSAENOTSOCK do return false, true
		else                       do return false, false
	}

	err_code_ := transmute(win.c_int)err_code
	if err_code_ != win.NO_ERROR {
		if err_code_ == win.WSAENOTSOCK do return false, true
		else                            do return false, false
	}

	return true, true
}

net_err_to_code :: proc(err: net.Network_Error) -> os.Errno {
	switch e in err {
	case net.Create_Socket_Error:
		return os.Errno(e)
	case net.Socket_Option_Error:
		return os.Errno(e)
	case net.General_Error:
		return os.Errno(e)
	case net.Platform_Error:
		return os.Errno(e)
	case net.Dial_Error:
		return os.Errno(e)
	case net.Listen_Error:
		return os.Errno(e)
	case net.Accept_Error:
		return os.Errno(e)
	case net.Bind_Error:
		return os.Errno(e)
	case net.TCP_Send_Error:
		return os.Errno(e)
	case net.UDP_Send_Error:
		return os.Errno(e)
	case net.TCP_Recv_Error:
		return os.Errno(e)
	case net.UDP_Recv_Error:
		return os.Errno(e)
	case net.Shutdown_Error:
		return os.Errno(e)
	case net.Set_Blocking_Error:
		return os.Errno(e)
	case net.Parse_Endpoint_Error:
		return os.Errno(e)
	case net.Resolve_Error:
		return os.Errno(e)
	case net.DNS_Error:
		return os.Errno(e)
	case:
		return os.ERROR_NONE
	}
}
