// +build darwin, linux
// +private
package nbio

import "core:net"
import "core:os"

_open :: proc(_: ^IO, path: string, mode, perm: int) -> (handle: os.Handle, errno: os.Errno) {
	handle, errno = os.open(path, mode, perm)
	if errno != os.ERROR_NONE do return

	errno = _prepare_handle(handle)
	if errno != os.ERROR_NONE do os.close(handle)
	return
}

_seek :: proc(_: ^IO, fd: os.Handle, offset: int, whence: Whence) -> (int, os.Errno) {
	r, err := os.seek(fd, i64(offset), int(whence))
	return int(r), err
}

_prepare_handle :: proc(fd: os.Handle) -> os.Errno {
	// NOTE: TCP_Socket gets cast to int right away in net, so this is safe to do.
	if err := net.set_blocking(net.TCP_Socket(fd), false); err != nil {
		return os.Errno(err.(net.Set_Blocking_Error))
	}
	return os.ERROR_NONE
}

_open_socket :: proc(
	_: ^IO,
	family: net.Address_Family,
	protocol: net.Socket_Protocol,
) -> (
	socket: net.Any_Socket,
	err: net.Network_Error,
) {
	socket, err = net.create_socket(family, protocol)
	if err != nil do return

	err = _prepare_socket(socket)
	if err != nil do net.close(socket)
	return
}

_prepare_socket :: proc(socket: net.Any_Socket) -> net.Network_Error {
	// TODO: set LINGER option?
	net.set_option(socket, .Reuse_Address, true) or_return
	net.set_option(socket, .TCP_Nodelay, true) or_return
	net.set_blocking(socket, false) or_return
	return nil
}
