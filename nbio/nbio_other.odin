//+build !js
package nbio

import "core:os"
import "core:net"

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

// TODO: remove
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
- io: The IO instance to use
- fd: The `Closable` socket or handle (created using/by this package) to close
*/
close :: proc {
	close_raw,
	close1,
	close2,
	close3,
}

/*
Using the given socket, accepts the next incoming connection, calling the callback when that happens

*Due to platform limitations, you must pass a socket that was opened using the `open_socket` and related procedures from this package*

TODO: this is also the case in other calls.

NOTE: if `close` is called on the socket while an `accept` is waiting in the event loop, the `accept` will never call back.

Inputs:
- io:     The IO instance to use
- socket: A bound and listening socket *that was created using this package*
*/
accept :: proc {
	accept_raw,
	accept1,
	accept2,
	accept3,
}

/*
Connects to the given endpoint, calling the given callback once it has been done

Inputs:
- io:       The IO instance to use
- endpoint: An endpoint to connect a socket to
*/
connect :: proc {
	connect_raw,
	connect1,
	connect2,
	connect3,
}

/*
Receives from the given socket, at most `len(buf)` bytes, and calls the given callback

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:     The IO instance to use
- socket: Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- buf:    The buffer to put received bytes into
*/
recv :: proc {
	recv_raw,
	recv1,
	recv2,
	recv3,
}

/*
Receives from the given socket until the given buf is full or an error occurred, and calls the given callback

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*

Inputs:
- io:     The IO instance to use
- socket: Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
- buf:    The buffer to put received bytes into
*/
recv_all :: proc {
	recv_all_raw,
	recv_all1,
	recv_all2,
	recv_all3,
}

/*
Sends at most `len(buf)` bytes from the given buffer over the socket connection, and calls the given callback

*Prefer using the `send` proc group*

*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- socket:   a `net.TCP_Socket` (that was opened/returned by this package) to send to
- buf:      The buffer send
*/
send :: proc {
	send_tcp_raw,
	send_tcp1,
	send_tcp2,
	send_tcp3,
	send_udp_raw,
	send_udp1,
	send_udp2,
	send_udp3,
}

/*
Sends the bytes from the given buffer over the socket connection, and calls the given callback

This will keep sending until either an error or the full buffer is sent

*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*
*/
send_all :: proc {
	send_all_tcp_raw,
	send_all_tcp1,
	send_all_tcp2,
	send_all_tcp3,
	send_all_udp_raw,
	send_all_udp1,
	send_all_udp2,
	send_all_udp3,
}

// TODO: remove.
/*
Reads from the given handle, at the handle's internal offset, at most `len(buf)` bytes, increases the file offset, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- buf:      The buffer to put read bytes into
*/
read :: proc {
	read_raw,
	read1,
	read2,
	read3,
}

// TODO: remove.
/*
Reads from the given handle, at the handle's internal offset, until the given buf is full or an error occurred, increases the file offset, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- buf:      The buffer to put read bytes into
*/
read_all :: proc {
	read_all_raw,
	read_all1,
	read_all2,
	read_all3,
}

/*
Reads from the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- offset:   The offset to begin the read from
- buf:      The buffer to put read bytes into
*/
read_at :: proc {
	read_at_raw,
	read_at1,
	read_at2,
	read_at3,
}

/*
Reads from the given handle, at the given offset, until the given buf is full or an error occurred, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to read from
- offset:   The offset to begin the read from
- buf:      The buffer to put read bytes into
*/
read_at_all :: proc {
	read_at_all_raw,
	read_at_all1,
	read_at_all2,
	read_at_all3,
}

/*
Writes to the given handle, at the handle's internal offset, at most `len(buf)` bytes, increases the file offset, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to
- buf:      The buffer to write to the file
*/
write :: proc {
	write_raw,
	write1,
	write2,
	write3,
}

/*
Writes the given buffer to the given handle, at the handle's internal offset, increases the file offset, and calls the given callback

This keeps writing until either an error or the full buffer being written

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to
- buf:      The buffer to write to the file
*/
write_all :: proc {
	write_all_raw,
	write_all1,
	write_all2,
	write_all3,
}

/*
Writes to the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

Inputs:
- io:       The IO instance to use
- fd:       The file handle (created using/by this package) to write to from
- offset:   The offset to begin the write from
- buf:      The buffer to write to the file
*/
write_at :: proc {
	write_at_raw,
	write_at1,
	write_at2,
	write_at3,
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
*/
write_at_all :: proc {
	write_at_all_raw,
	write_at_all1,
	write_at_all2,
	write_at_all3,
}

Poll_Event :: enum {
	// The subject is ready to be read from.
	Read,
	// The subject is ready to be written to.
	Write,
}

/*
Polls for the given event on the subject handle

Inputs:
- io:       The IO instance to use
- fd:       The file descriptor to poll
- event:    Whether to call the callback when `fd` is ready to be read from, or be written to
- multi:    Keeps the poll after an event happens, calling the callback again for further events, remove poll with `remove`
*/
poll :: proc {
	poll_raw,
	poll1,
	poll2,
	poll3,
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
	Op_Next_Tick,
	Op_Poll,
	Op_Remove,
}
