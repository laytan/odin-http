package nbio

import "core:net"
import "core:os"
import "core:time"

/*
The main IO type that holds the platform dependant implementation state passed around most procedures in this package
*/
IO :: _IO

/*
Initializes the IO type, allocates different things per platform needs

*Allocates Using Provided Allocator*

Inputs:
- io:        The IO struct to initialize
- allocator: (default: context.allocator)

Returns:
- err: An error code when something went wrong with the setup of the platform's IO API, 0 otherwise
*/
init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {
	return _init(io, allocator)
}

/*
The place where the magic happens, each time you call this the IO implementation checks its state
and calls any callbacks which are ready. You would typically call this in a loop

Inputs:
- io: The IO instance to tick

Returns:
- err: An error code when something went when retrieving events, 0 otherwise
*/
tick :: proc(io: ^IO) -> os.Errno {
	return _tick(io)
}

/*
Returns the number of in-progress IO to be completed.
*/
num_waiting :: #force_inline proc(io: ^IO) -> int {
	return _num_waiting(io)
}

/*
Deallocates anything that was allocated when calling init()

Inputs:
- io: The IO instance to deallocate

*Deallocates with the allocator that was passed with the init() call*
*/
destroy :: proc(io: ^IO) {
	_destroy(io)
}

/*
The callback for non blocking `timeout` calls

Inputs:
- user:           A passed through pointer from initiation to its callback
- completed_time: The time at which the callback is called, this is not available on all platforms
                  which is why it is a Maybe, you can do `now := completed_time.? or_else time.now()`
                  if you need the time.
*/
On_Timeout :: #type proc(user: rawptr, completed_time: Maybe(time.Time))

/*
Schedules a callback to be called after the given duration elapses.

The accuracy depends on the time between calls to `tick`.
When you call it in a loop with no blocks or very expensive calculations in other scheduled event callbacks
it is reliable to about a ms of difference (so timeout of 10ms would almost always be ran between 10ms and 11ms).

Inputs:
- io:       The IO instance to use
- dur:      The minimum duration to wait before calling the given callback
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Timeout` for its arguments
*/
timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {
	_timeout(io, dur, user, callback)
}

/*
Creates a socket, sets non blocking mode and relates it to the given IO

Inputs:
- io:       The IO instance to initialize the socket on/with
- family:   Should this be an IP4 or IP6 socket
- protocol: The type of socket (TCP or UDP)

Returns:
- socket: The opened socket
- err:    A network error that happened while opening
*/
open_socket :: proc(
	io: ^IO,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	return _open_socket(io, family, protocol)
}

/*
Creates a socket, sets non blocking mode, relates it to the given IO, binds the socket to the given endpoint and starts listening

Inputs:
- io:       The IO instance to initialize the socket on/with
- endpoint: Where to bind the socket to

Returns:
- socket: The opened, bound and listening socket
- err:    A network error that happened while opening
*/
open_and_listen_tcp :: proc(io: ^IO, ep: net.Endpoint) -> (socket: net.TCP_Socket, err: net.Network_Error) {
	family := net.family_from_endpoint(ep)
	sock := open_socket(io, family, .TCP) or_return
	socket = sock.(net.TCP_Socket)

	if err = net.bind(socket, ep); err != nil {
		close(io, socket)
		return
	}

	if err = listen(socket); err != nil {
		close(io, socket)
	}
	return
}

/*
Starts listening on the given socket

Inputs:
- socket:  The socket to start listening
- backlog: The amount of events to keep in the backlog when they are not consumed

Returns:
- err: A network error that happened when starting listening
*/
listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Network_Error) {
	return _listen(socket, backlog)
}

/*
The callback for non blocking `close` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- ok:   Whether the operation suceeded sucessfully
*/
On_Close :: #type proc(user: rawptr, ok: bool)

@private
empty_on_close :: proc(_: rawptr, _: bool) {}

/*
A union of types that are `close`'able by this package
*/
Closable :: union #no_nil {
	net.TCP_Socket,
	net.UDP_Socket,
	net.Socket,
	os.Handle,
}

/*
Closes the given `Closable` socket or file handle that was originally created by this package.

*Due to platform limitations, you must pass a `Closable` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The `Closable` socket or handle (created using/by this package) to close
- user:     An optional pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: An optional callback that is called when the operation completes, see docs for `On_Close` for its arguments
*/
close :: proc(io: ^IO, fd: Closable, user: rawptr = nil, callback: On_Close = empty_on_close) {
	_close(io, fd, user, callback)
}

/*
The callback for non blocking `accept` requests

Inputs:
- user:   A passed through pointer from initiation to its callback
- client: The socket to communicate through with the newly accepted client
- source: The origin of the client
- err:    A network error that occured during the accept process
*/
On_Accept :: #type proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)

/*
Using the given socket, accepts the next incoming connection, calling the callback when that happens

*Due to platform limitations, you must pass a socket that was opened using the `open_socket` and related procedures from this package*

Inputs:
- io:       The IO instance to use
- socket:   A bound and listening socket *that was created using this package*
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Accept` for its arguments
*/
accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {
	_accept(io, socket, user, callback)
}

/*
The callback for non blocking `connect` requests

Inputs:
- user:   A passed through pointer from initiation to its callback
- socket: A socket that is connected to the given endpoint in the `connect` call
- err:    A network error that occured during the connect call
*/
On_Connect :: #type proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error)

/*
Connects to the given endpoint, calling the given callback once it has been done

Inputs:
- io:       The IO instance to use
- endpoint: An endpoint to connect a socket to
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Connect` for its arguments
*/
connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {
	_, err := _connect(io, endpoint, user, callback)
	if err != nil {
		callback(user, {}, err)
	}
}

/*
The callback for non blocking `recv` requests

Inputs:
- user:       A passed through pointer from initiation to its callback
- received:   The amount of bytes that were read and added to the given buf
- udp_client: If the given socket was a `net.UDP_Socket`, this will be the client that was received from
- err:        A network error if it occured
*/
On_Recv :: #type proc(user: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)

/*
Receives from the given socket, at most `len(buf)` bytes, and calls the given callback

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- buf:      The buffer to put received bytes into
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Recv` for its arguments
*/
recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	_recv(io, socket, buf, user, callback)
}

/*
Receives from the given socket until the given buf is full or an error occurred, and calls the given callback

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- buf:      The buffer to put received bytes into
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Recv` for its arguments
*/
recv_all :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {
	_recv(io, socket, buf, user, callback, all = true)
}

/*
The callback for non blocking `send` and `send_all` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- sent: The amount of bytes that were sent over the connection
- err:  A network error if it occured
*/
On_Sent :: #type proc(user: rawptr, sent: int, err: net.Network_Error)

/*
Sends at most `len(buf)` bytes from the given buffer over the socket connection, and calls the given callback

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   a `net.TCP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments
*/
send_tcp :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {
	_send(io, socket, buf, user, callback)
}

/*
Sends at most `len(buf)` bytes from the given buffer over the socket connection to the given endpoint, and calls the given callback

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- endpoint: The endpoint to send bytes to over the socket
- socket:   a `net.UDP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments
*/
send_udp :: proc(
	io: ^IO,
	endpoint: net.Endpoint,
	socket: net.UDP_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
) {
	_send(io, socket, buf, user, callback, endpoint)
}

/*
Sends at most `len(buf)` bytes from the given buffer over the socket connection, and calls the given callback

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*
*/
send :: proc {
	send_udp,
	send_tcp,
}

/*
Sends the bytes from the given buffer over the socket connection, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   a `net.TCP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments
*/
send_all_tcp :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {
	_send(io, socket, buf, user, callback, all = true)
}

/*
Sends the bytes from the given buffer over the socket connection to the given endpoint, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- endpoint: The endpoint to send bytes to over the socket
- socket:   a `net.UDP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments
*/
send_all_udp :: proc(
	io: ^IO,
	endpoint: net.Endpoint,
	socket: net.UDP_Socket,
	buf: []byte,
	user: rawptr,
	callback: On_Sent,
) {
	_send(io, socket, buf, user, callback, endpoint, all = true)
}

/*
Sends the bytes from the given buffer over the socket connection, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*
*/
send_all :: proc {
	send_all_udp,
	send_all_tcp,
}

/*
Opens a file hande, sets non blocking mode and relates it to the given IO

*The perm argument is only used when on the darwin or linux platforms, when on Windows you can't use the os.S_\* constants because they aren't declared*
*To prevent compilation errors on Windows, you should use a `when` statement around using those constants and just pass 0*

Inputs:
- io:   The IO instance to connect the opened file to
- mode: The file mode                                 (default: os.O_RDONLY)
- perm: The permissions to use when creating a file   (default: 0)

Returns:
- handle: The file handle
- err:    The error code when an error occured, 0 otherwise
*/
open :: proc(io: ^IO, path: string, mode: int = os.O_RDONLY, perm: int = 0) -> (handle: os.Handle, err: os.Errno) {
	return _open(io, path, mode, perm)
}

/*
Where to seek from

Options:
- Set:  sets the offset to the given value
- Curr: adds the given offset to the current offset
- End:  adds the given offset to the end of the file
*/
Whence :: enum {
	Set,
	Curr,
	End,
}

/*
Seeks the given handle according to the given offset and whence, so that subsequent read and writes *USING THIS PACKAGE* will do so at that offset

*Some platforms require this package to handle offsets while others have state in the kernel, for this reason you should assume that seeking only affects this package*

Inputs:
- io:     The IO instance to seek on
- fd:     The file handle to seek
- whence: The seek mode/where to seek from (default: Whence.Set)

Returns:
- new_offset: The offset that the file is at when the operation completed
- err:        The error when an error occured, 0 otherwise
*/
seek :: proc(io: ^IO, fd: os.Handle, offset: int, whence: Whence = .Set) -> (new_offset: int, err: os.Errno) {
	return _seek(io, fd, offset, whence)
}

/*
The callback for non blocking `read` or `read_at` requests

Inputs:
- user: A passed through pointer from initiation to its callback
- read: The amount of bytes that were read and added to the given buf
- err:  An error number if an error occured, 0 otherwise
*/
On_Read :: #type proc(user: rawptr, read: int, err: os.Errno)

/*
Reads from the given handle, at the handle's internal offset, at most `len(buf)` bytes, increases the file offset, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- buf:      The buffer to put read bytes into
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments
*/
read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	_read(io, fd, nil, buf, user, callback)
}

/*
Reads from the given handle, at the handle's internal offset, until the given buf is full or an error occurred, increases the file offset, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- buf:      The buffer to put read bytes into
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments
*/
read_all :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {
	_read(io, fd, nil, buf, user, callback, all = true)
}

/*
Reads from the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- offset:   The offset to begin the read from
- buf:      The buffer to put read bytes into
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments
*/
read_at :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) {
	_read(io, fd, offset, buf, user, callback)
}

/*
Reads from the given handle, at the given offset, until the given buf is full or an error occurred, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- offset:   The offset to begin the read from
- buf:      The buffer to put read bytes into
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments
*/
read_at_all :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) {
	_read(io, fd, offset, buf, user, callback, all = true)
}

read_entire_file :: read_full

/*
Reads the entire file (size found by seeking to the end) into a singly allocated buffer that is returned.
The callback is called once the file is read into the returned buf.

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments

Returns:
- buf:      The buffer allocated to the size retrieved by seeking to the end of the file that is filled before calling the callback
*/
read_full :: proc(io: ^IO, fd: os.Handle, user: rawptr, callback: On_Read, allocator := context.allocator) -> []byte {
	size, err := seek(io, fd, 0, .End)
	if err != os.ERROR_NONE {
		callback(user, 0, err)
		return nil
	}

	if size <= 0 {
		callback(user, 0, os.ERROR_NONE)
		return nil
	}

	buf := make([]byte, size, allocator)
	read_at_all(io, fd, 0, buf, user, callback)
	return buf
}

/*
The callback for non blocking `write`, `write_all`, `write_at` and `write_at_all` requests

Inputs:
- user:     A passed through pointer from initiation to its callback
- written:  The amount of bytes that were written to the file
- err:      An error number if an error occured, 0 otherwise
*/
On_Write :: #type proc(user: rawptr, written: int, err: os.Errno)

/*
Writes to the given handle, at the handle's internal offset, at most `len(buf)` bytes, increases the file offset, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to
- buf:      The buffer to write to the file
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Write` for its arguments
*/
write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	_write(io, fd, nil, buf, user, callback)
}

/*
Writes the given buffer to the given handle, at the handle's internal offset, increases the file offset, and calls the given callback

This keeps writing until either an error or the full buffer being written

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to
- buf:      The buffer to write to the file
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Write` for its arguments
*/
write_all :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {
	_write(io, fd, nil, buf, user, callback, true)
}

/*
Writes to the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to from
- offset:   The offset to begin the write from
- buf:      The buffer to write to the file
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Write` for its arguments
*/
write_at :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) {
	_write(io, fd, offset, buf, user, callback)
}

/*
Writes the given buffer to the given handle, at the given offset, and calls the given callback

This keeps writing until either an error or the full buffer being written

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to from
- offset:   The offset to begin the write from
- buf:      The buffer to write to the file
- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
- callback: The callback that is called when the operation completes, see docs for `On_Write` for its arguments
*/
write_at_all :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) {
	_write(io, fd, offset, buf, user, callback, true)
}

MAX_USER_ARGUMENTS :: size_of(rawptr) * 5

Completion :: struct {
	// Implementation specifics, don't use outside of implementation/os.
	using _:   _Completion,

	user_data: rawptr,

	// Callback pointer and user args passed in poly variants.
	user_args: [MAX_USER_ARGUMENTS + size_of(rawptr)]byte,
}

@(private)
Operation :: union #no_nil {
	Op_Accept,
	Op_Close,
	Op_Connect,
	Op_Read,
	Op_Recv,
	Op_Send,
	Op_Write,
	Op_Timeout,
}
