# package nbio

Package nbio implements a non blocking IO abstraction layer over several platform specific APIs.

This package implements an event loop based abstraction.

*TODO:*

- Windows implementation has a bug I can't figure out where we can only retrieve one queued event at a time
- Benchmarking
- Some UDP implementations

*APIs:*

- Windows: [IOCP (IO Completion Ports)](https://en.wikipedia.org/wiki/Input/output_completion_port)
- Linux:   [io_uring](https://en.wikipedia.org/wiki/Io_uring)
- Darwin:  [KQueue](https://en.wikipedia.org/wiki/Kqueue)

*How to read the code:*

The file nbio.odin can be read a little bit like a header file,
it has all the procedures heavily explained and commented and dispatches them to platform specific code.

You can also have a look at the tests for more general usages, the example below or the generated docs even further below.

```odin
/*
This example shows a simple TCP server that echos back anything it receives.

Better error handling and closing/freeing connections are left for the reader.
*/
package main

import "core:fmt"
import "core:net"
import "core:os"

import "nbio"

Echo_Server :: struct {
	io:          nbio.IO,
	sock:        net.TCP_Socket,
	connections: [dynamic]^Echo_Connection
}

Echo_Connection :: struct {
	server:  ^Echo_Server,
	sock:    net.TCP_Socket,
	buf:     [50]byte,
}

main :: proc() {
	server: Echo_Server
	defer delete(server.connections)

	nbio.init(&server.io)
	defer nbio.destroy(&server.io)

	sock, err := nbio.open_and_listen_tcp(&server.io, {net.IP4_Loopback, 8080})
	fmt.assertf(err == nil, "Error opening and listening on localhost:8080: %v", err)
	server.sock = sock

	nbio.accept(&server.io, sock, &server, echo_on_accept)

	// Start the event loop.
	errno: os.Errno
	for errno == os.ERROR_NONE {
		errno = nbio.tick(&server.io)
	}

	fmt.assertf(errno == os.ERROR_NONE, "Server stopped with error code: %v", errno)
}

echo_on_accept :: proc(server: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error) {
	fmt.assertf(err == nil, "Error accepting a connection: %v", err)
	server := cast(^Echo_Server)server

	// Register a new accept for the next client.
	nbio.accept(&server.io, server.sock, server, echo_on_accept)

	c := new(Echo_Connection)
	c.server = server
	c.sock   = client
	append(&server.connections, c)

	nbio.recv(&server.io, client, c.buf[:], c, echo_on_recv)
}

echo_on_recv :: proc(c: rawptr, received: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
	fmt.assertf(err == nil, "Error receiving from client: %v", err)
	c := cast(^Echo_Connection)c

	nbio.send(&c.server.io, c.sock, c.buf[:received], c, echo_on_sent)
}

echo_on_sent :: proc(c: rawptr, sent: int, err: net.Network_Error) {
	fmt.assertf(err == nil, "Error sending to client: %v", err)
	c := cast(^Echo_Connection)c

	// Accept the next message, to then ultimately echo back again.
	nbio.recv(&c.server.io, c.sock, c.buf[:], c, echo_on_recv)
}
```

```
procedures
	accept :: proc(io: ^IO, socket: net.TCP_Socket, user: rawptr, callback: On_Accept) {...}
		Using the given socket, accepts the next incoming connection, calling the callback when that happens

		*Due to platform limitations, you must pass a socket that was opened using the `open_socket` and related procedures from this package*

		Inputs:
		- io:       The IO instance to use
		- socket:   A bound and listening socket *that was created using this package*
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Accept` for its arguments

	close :: proc(io: ^IO, fd: Closable, user: rawptr, callback: On_Close) {...}
		Closes the given `Closable` socket or file handle that was originally created by this package.

		*Due to platform limitations, you must pass a `Closable` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- fd:       The `Closable` socket or handle (created using/by this package) to close
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Close` for its arguments

	connect :: proc(io: ^IO, endpoint: net.Endpoint, user: rawptr, callback: On_Connect) {...}
		Connects to the given endpoint, calling the given callback once it has been done

		Inputs:
		- io:       The IO instance to use
		- endpoint: An endpoint to connect a socket to
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Connect` for its arguments

	destroy :: proc(io: ^IO) {...}
		Deallocates anything that was allocated when calling init()

		Inputs:
		- io: The IO instance to deallocate

		*Deallocates with the allocator that was passed with the init() call*

	init :: proc(io: ^IO, allocator := context.allocator) -> (err: os.Errno) {...}
		Initializes the IO type, allocates different things per platform needs

		*Allocates Using Provided Allocator*

		Inputs:
		- io:        The IO struct to initialize
		- allocator: (default: context.allocator)

		Returns:
		- err: An error code when something went wrong with the setup of the platform's IO API, 0 otherwise

	listen :: proc(socket: net.TCP_Socket, backlog := 1000) -> (err: net.Network_Error) {...}
		Starts listening on the given socket

		Inputs:
		- socket:  The socket to start listening
		- backlog: The amount of events to keep in the backlog when they are not consumed

		Returns:
		- err: A network error that happened when starting listening

	open :: proc(io: ^IO, path: string, mode: int = os.O_RDONLY, perm: int = 0) -> (handle: os.Handle, err: os.Errno) {...}
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

	open_and_listen_tcp :: proc(io: ^IO, ep: net.Endpoint) -> (socket: net.TCP_Socket, err: net.Network_Error) {...}
		Creates a socket, sets non blocking mode, relates it to the given IO, binds the socket to the given endpoint and starts listening

		Inputs:
		- io:       The IO instance to initialize the socket on/with
		- endpoint: Where to bind the socket to

		Returns:
		- socket: The opened, bound and listening socket
		- err:    A network error that happened while opening

	open_socket :: proc(io: ^IO, family: net.Address_Family, protocol: net.Socket_Protocol) -> (socket: net.Any_Socket, err: net.Network_Error) {...}
		Creates a socket, sets non blocking mode and relates it to the given IO

		Inputs:
		- io:       The IO instance to initialize the socket on/with
		- family:   Should this be an IP4 or IP6 socket
		- protocol: The type of socket (TCP or UDP)

		Returns:
		- socket: The opened socket
		- err:    A network error that happened while opening

	read :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Read) {...}
		Reads from the given handle, at the handle's internal offset, at most `len(buf)` bytes, increases the file offset, and calls the given callback

		*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- fd:       The file handle (created using/by this package) to read from
		- buf:      The buffer to put read bytes into
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments

	read_at :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Read) {...}
		Reads from the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

		*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- fd:       The file handle (created using/by this package) to read from
		- offset:   The offset to begin the read from
		- buf:      The buffer to put read bytes into
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Read` for its arguments

	recv :: proc(io: ^IO, socket: net.Any_Socket, buf: []byte, user: rawptr, callback: On_Recv) {...}
		Receives from the given socket, at most `len(buf)` bytes, and calls the given callback

		*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- socket:   Either a `net.TCP_Socket` or a `net.UDP_Socket` (that was opened/returned by this package) to receive from
		- buf:      The buffer to put received bytes into
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Recv` for its arguments

	seek :: proc(io: ^IO, fd: os.Handle, offset: int, whence: Whence = .Set) -> (new_offset: int, err: os.Errno) {...}
		Seeks the given handle according to the given offset and whence, so that subsequent read and writes *USING THIS PACKAGE* will do so at that offset

		*Some platforms require this package to handle offsets while others have state in the kernel, for this reason you should assume that seeking only affects this package*

		Inputs:
		- io:     The IO instance to seek on
		- fd:     The file handle to seek
		- whence: The seek mode/where to seek from (default: Whence.Set)

		Returns:
		- new_offset: The offset that the file is at when the operation completed
		- err:        The error when an error occured, 0 otherwise

	send_tcp :: proc(io: ^IO, socket: net.TCP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {...}
		Sends at most `len(buf)` bytes from the given buffer over the socket connection, and calls the given callback

		*Prefer using the `send` proc group*

		*Due to platform limitations, you must pass a `net.TCP_Socket` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- socket:   a `net.TCP_Socket` (that was opened/returned by this package) to send to
		- buf:      The buffer send
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Sent` for its arguments

	send_udp :: proc(io: ^IO, endpoint: net.Endpoint, socket: net.UDP_Socket, buf: []byte, user: rawptr, callback: On_Sent) {...}
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

	tick :: proc(io: ^IO) -> os.Errno {...}
		The place where the magic happens, each time you call this the IO implementation checks its state
		and calls any callbacks which are ready. You would typically call this in a loop

		Inputs:
		- io: The IO instance to tick

		Returns:
		- err: An error code when something went when retrieving events, 0 otherwise

	timeout :: proc(io: ^IO, dur: time.Duration, user: rawptr, callback: On_Timeout) {...}
		Schedules a callback to be called after the given duration elapses.

		The accuracy depends on the time between calls to `tick`,
		accuracy is pretty good when you call it in a loop with no sleeps or very expensive calculations in other scheduled event callbacks

		Inputs:
		- io:       The IO instance to use
		- dur:      The minimum duration to wait before calling the given callback
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Timeout` for its arguments

	write :: proc(io: ^IO, fd: os.Handle, buf: []byte, user: rawptr, callback: On_Write) {...}
		Writes to the given handle, at the handle's internal offset, at most `len(buf)` bytes, increases the file offset, and calls the given callback

		*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- fd:       The file handle (created using/by this package) to write to
		- buf:      The buffer to write to the file
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Write` for its arguments

	write_at :: proc(io: ^IO, fd: os.Handle, offset: int, buf: []byte, user: rawptr, callback: On_Write) {...}
		Writes to the given handle, at the given offset, at most `len(buf)` bytes, and calls the given callback

		*Due to platform limitations, you must pass a `os.Handle` that was opened/returned using/by this package*

		Inputs:
		- io:       The IO instance to use
		- fd:       The file handle (created using/by this package) to write to from
		- offset:   The offset to begin the write from
		- buf:      The buffer to write to the file
		- user:     A pointer that will be passed through to the callback, free to use by you and untouched by us
		- callback: The callback that is called when the operation completes, see docs for `On_Write` for its arguments


proc_group
	send :: proc{send_udp, send_tcp}
		Sends at most `len(buf)` bytes from the given buffer over the socket connection, and calls the given callback

		*Due to platform limitations, you must pass a `net.TCP_Socket` or `net.UDP_Socket` that was opened/returned using/by this package*


types
	Closable :: union #no_nil {net.TCP_Socket, net.UDP_Socket, os.Handle}
		A union of types that are `close`'able by this package

	IO :: struct {impl_data: rawptr}
		The main IO type that holds the platform dependant implementation state passed around most procedures in this package

	On_Accept :: #type proc(user: rawptr, client: net.TCP_Socket, source: net.Endpoint, err: net.Network_Error)
		The callback for non blocking `accept` requests

		Inputs:
		- user:   A passed through pointer from initiation to its callback
		- client: The socket to communicate through with the newly accepted client
		- source: The origin of the client
		- err:    A network error that occured during the accept process

	On_Close :: #type proc(user: rawptr, ok: bool)
		The callback for non blocking `close` requests

		Inputs:
		- user: A passed through pointer from initiation to its callback
		- ok:   Whether the operation suceeded sucessfully

	On_Connect :: #type proc(user: rawptr, socket: net.TCP_Socket, err: net.Network_Error)
		The callback for non blocking `connect` requests

		Inputs:
		- user:   A passed through pointer from initiation to its callback
		- socket: A socket that is connected to the given endpoint in the `connect` call
		- err:    A network error that occured during the connect call

	On_Read :: #type proc(user: rawptr, read: int, err: os.Errno)
		The callback for non blocking `read` or `read_at` requests

		Inputs:
		- user: A passed through pointer from initiation to its callback
		- read: The amount of bytes that were read and added to the given buf
		- err:  An error number if an error occured, 0 otherwise

	On_Recv :: #type proc(user: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error)
		The callback for non blocking `recv` requests

		Inputs:
		- user:       A passed through pointer from initiation to its callback
		- received:   The amount of bytes that were read and added to the given buf
		- udp_client: If the given socket was a `net.UDP_Socket`, this will be the client that was received from
		- err:        A network error if it occured

	On_Sent :: #type proc(user: rawptr, sent: int, err: net.Network_Error)
		The callback for non blocking `send` requests

		Inputs:
		- user: A passed through pointer from initiation to its callback
		- sent: The amount of bytes that were sent over the connection
		- err:  A network error if it occured

	On_Timeout :: #type proc(user: rawptr, completed_time: Maybe(time.Time))
		The callback for non blocking `timeout` calls

		Inputs:
		- user:           A passed through pointer from initiation to its callback
		- completed_time: The time at which the callback is called, this is not available on all platforms
                          which is why it is a Maybe, you can do `now := completed_time.? or_else time.now()`
                          if you need the time.

	On_Write :: #type proc(user: rawptr, written: int, err: os.Errno)
		The callback for non blocking `write` or `write_at` requests

		Inputs:
		- user:     A passed through pointer from initiation to its callback
		- written: The amount of bytes that were written to the file
		- err:     An error number if an error occured, 0 otherwise

	Whence :: enum {Set, Curr, End}
		Where to seek from

		Options:
		- Set:  sets the offset to the given value
		- Curr: adds the given offset to the current offset
		- End:  adds the given offset to the end of the file
```
