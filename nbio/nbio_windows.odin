package nbio

import "core:container/queue"
import "core:log"
import "core:net"
import "core:os"
import "core:time"

import win "core:sys/windows"

_init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	io.allocator = allocator

	pool_init(&io.completion_pool, allocator = allocator)
	queue.init(&io.completed, allocator = allocator)
	io.timeouts = make([dynamic]^Completion, allocator)
	io.offsets = make(map[os.Handle]u32, allocator = allocator)

	win.ensure_winsock_initialized()
	defer if err != win.NO_ERROR {
		assert(win.WSACleanup() == win.NO_ERROR)
	}

	io.iocp = win.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, nil, nil, 0)
	if io.iocp == nil {
		err = os.Errno(win.GetLastError())
		return
	}

	return
}

_destroy :: proc(io: ^IO) {
	delete(io.timeouts)
	queue.destroy(&io.completed)
	pool_destroy(&io.completion_pool)
	delete(io.offsets)

	// TODO: error handling.
	win.CloseHandle(io.iocp)
	// win.WSACleanup()
}

_num_waiting :: #force_inline proc(io: ^IO) -> int {
	return io.completion_pool.num_waiting
}

_tick :: proc(io: ^IO) -> (err: os.Errno) {
	if queue.len(io.completed) == 0 {
		next_timeout := flush_timeouts(io)

		// Wait a maximum of a ms if there is nothing to do.
		// TODO: this is pretty naive, a typical server always has accept completions pending and will be at 100% cpu.
		wait_ms: win.DWORD = 1 if io.io_pending == 0 else 0

		// But, to counter inaccuracies in low timeouts,
		// lets make the call exit immediately if the next timeout is close.
		if nt, ok := next_timeout.?; ok && nt <= time.Millisecond * 15 {
			wait_ms = 0
		}

		events: [256]win.OVERLAPPED_ENTRY
		entries_removed: win.ULONG
		if !win.GetQueuedCompletionStatusEx(io.iocp, &events[0], len(events), &entries_removed, wait_ms, false) {
			if terr := win.GetLastError(); terr != win.WAIT_TIMEOUT {
				err = os.Errno(terr)
				return
			}
		}

		// assert(io.io_pending >= int(entries_removed))
		io.io_pending -= int(entries_removed)

		for event in events[:entries_removed] {
			if event.lpOverlapped == nil {
				@static logged: bool
				if !logged {
					log.warn("You have ran into a strange error some users have ran into on Windows 10 but I can't reproduce, I try to recover from the error but please chime in at https://github.com/laytan/odin-http/issues/34")
					logged = true
				}

				io.io_pending += 1
				continue
			}

			// This is actually pointing at the Completion.over field, but because it is the first field
			// It is also a valid pointer to the Completion struct.
			completion := transmute(^Completion)event.lpOverlapped
			queue.push_back(&io.completed, completion)
		}
	}

	// Prevent infinite loop when callback adds to completed by storing length.
	n := queue.len(io.completed)
	for _ in 0 ..< n {
		completion := queue.pop_front(&io.completed)
		context = completion.ctx

		handle_completion(io, completion)
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
	//odinfmt:disable
	switch mode & (os.O_RDONLY | os.O_WRONLY | os.O_RDWR) {
	case os.O_RDONLY: access = win.FILE_GENERIC_READ
	case os.O_WRONLY: access = win.FILE_GENERIC_WRITE
	case os.O_RDWR:   access = win.FILE_GENERIC_READ | win.FILE_GENERIC_WRITE
	}
	//odinfmt:enable

	if mode & os.O_CREATE != 0 {
		access |= win.FILE_GENERIC_WRITE
	}
	if mode & os.O_APPEND != 0 {
		access &~= win.FILE_GENERIC_WRITE
		access |= win.FILE_APPEND_DATA
	}

	share_mode := win.FILE_SHARE_READ | win.FILE_SHARE_WRITE
	sa: ^win.SECURITY_ATTRIBUTES = nil
	sa_inherit := win.SECURITY_ATTRIBUTES {
		nLength        = size_of(win.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	if mode & os.O_CLOEXEC == 0 {
		sa = &sa_inherit
	}

	create_mode: u32
	switch {
	case mode & (os.O_CREATE | os.O_EXCL) == (os.O_CREATE | os.O_EXCL):
		create_mode = win.CREATE_NEW
	case mode & (os.O_CREATE | os.O_TRUNC) == (os.O_CREATE | os.O_TRUNC):
		create_mode = win.CREATE_ALWAYS
	case mode & os.O_CREATE == os.O_CREATE:
		create_mode = win.OPEN_ALWAYS
	case mode & os.O_TRUNC == os.O_TRUNC:
		create_mode = win.TRUNCATE_EXISTING
	case:
		create_mode = win.OPEN_EXISTING
	}

	flags := win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_BACKUP_SEMANTICS

	// This line is the only thing different from the `os.open` procedure.
	// This makes it an asynchronous file that can be used in nbio.
	flags |= win.FILE_FLAG_OVERLAPPED

	wide_path := win.utf8_to_wstring(path)
	handle := os.Handle(win.CreateFileW(wide_path, access, share_mode, sa, create_mode, flags, nil))

	if handle == os.INVALID_HANDLE {
		err := os.Errno(win.GetLastError())
		return os.INVALID_HANDLE, err
	}

	// Everything past here is custom/not from `os.open`.

	handle_iocp := win.CreateIoCompletionPort(win.HANDLE(handle), io.iocp, nil, 0)
	assert(handle_iocp == io.iocp)

	cmode: byte
	cmode |= FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
	cmode |= FILE_SKIP_SET_EVENT_ON_HANDLE
	if !win.SetFileCompletionNotificationModes(win.HANDLE(handle), cmode) {
		win.CloseHandle(win.HANDLE(handle))
		return os.INVALID_HANDLE, os.Errno(win.GetLastError())
	}

	if mode & os.O_APPEND != 0 {
		_seek(io, handle, 0, .End)
	}

	return handle, os.ERROR_NONE
}

_seek :: proc(io: ^IO, fd: os.Handle, offset: int, whence: Whence) -> (int, os.Errno) {
	switch whence {
	case .Set:
		io.offsets[fd] = u32(offset)
	case .Curr:
		io.offsets[fd] += u32(offset)
	case .End:
		size: win.LARGE_INTEGER
		ok := win.GetFileSizeEx(win.HANDLE(fd), &size)
		if !ok {
			return 0, os.Errno(win.GetLastError())
		}

		io.offsets[fd] = u32(size) + u32(offset)
	}

	return int(io.offsets[fd]), os.ERROR_NONE
}

_open_socket :: proc(
	io: ^IO,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	socket, err = net.create_socket(family, protocol)
	if err != nil do return

	err = prepare_socket(io, socket)
	if err != nil do net.close(socket)
	return
}

_accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) -> ^Completion {
	return submit(
		io,
		user,
		Op_Accept{
			callback = callback,
			socket   = win.SOCKET(socket),
			client   = win.INVALID_SOCKET,
		},
	)
}

_connect :: proc(io: ^IO, ep: net.Endpoint, user: rawptr, callback: On_Connect) -> (^Completion, net.Network_Error) {
	if ep.port == 0 {
		return nil, net.Dial_Error.Port_Required
	}

	return submit(io, user, Op_Connect{
		callback = callback,
		addr     = endpoint_to_sockaddr(ep),
	}), nil
}

_close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) -> ^Completion {
	return submit(io, user, Op_Close{callback = callback, fd = fd})
}

_read :: proc(
	io: ^IO,
	fd: os.Handle,
	offset: Maybe(int),
	buf: []byte,
	user: rawptr,
	callback: On_Read,
	all := false,
) -> ^Completion {
	return submit(io, user, Op_Read{
		callback = callback,
		fd       = fd,
		offset   = offset.? or_else -1,
		buf      = buf,
		all      = all,
		len      = len(buf),
	})
}

_write :: proc(
	io: ^IO,
	fd: os.Handle,
	offset: Maybe(int),
	buf: []byte,
	user: rawptr,
	callback: On_Write,
	all := false,
) -> ^Completion {
	return submit(io, user, Op_Write{
		callback = callback,
		fd       = fd,
		offset   = offset.? or_else -1,
		buf      = buf,

		all      = all,
		len      = len(buf),
	})
}

_recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv, all := false) -> ^Completion {
	// TODO: implement UDP.
	if _, ok := socket.(net.UDP_Socket); ok do unimplemented("nbio.recv with UDP sockets is not yet implemented")

	return submit(
		io,
		user,
		Op_Recv{
			callback = callback,
			socket   = socket,
			buf      = win.WSABUF{len = win.ULONG(len(buf)), buf = raw_data(buf)},
			all      = all,
			len      = len(buf),
		},
	)
}

_send :: proc(
	io: ^IO,
	socket: net.Any_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
	endpoint: Maybe(net.Endpoint) = nil,
	all := false,
) -> ^Completion {
	// TODO: implement UDP.
	if _, ok := socket.(net.UDP_Socket); ok do unimplemented("nbio.send with UDP sockets is not yet implemented")

	return submit(
		io,
		user,
		Op_Send{
			callback = callback,
			socket   = socket,
			buf      = win.WSABUF{len = win.ULONG(len(buf)), buf = raw_data(buf)},

			all      = all,
			len      = len(buf),
		},
	)
}

_timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) -> ^Completion {
	completion := pool_get(&io.completion_pool)

	completion.op = Op_Timeout {
		callback = callback,
		expires  = time.time_add(time.now(), dur),
	}
	completion.user_data = user
	completion.ctx = context

	append(&io.timeouts, completion)
	return completion
}

