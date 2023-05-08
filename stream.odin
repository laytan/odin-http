package http

import "core:io"
import "core:net"
import "core:log"

// Wraps a tcp socket with a stream.
tcp_stream :: proc(sock: net.TCP_Socket) -> (s: io.Stream) {
    s.stream_data = rawptr(uintptr(sock))
    s.stream_vtable = &_socket_stream_vtable
    return s
}

@(private)
_socket_stream_vtable := io.Stream_VTable {
	impl_read = proc(s: io.Stream, p: []byte) -> (n: int, err: io.Error) {
		sock := net.TCP_Socket(uintptr(s.stream_data))
		read, e := net.recv_tcp(sock, p)
		n = read
		#partial switch ex in e {
		case net.TCP_Recv_Error:
			switch ex {
			case .None:
				err = .None
			case .Shutdown, .Not_Connected, .Connection_Broken, .Aborted, .Connection_Closed, .Offline, .Host_Unreachable, .Interrupted, .Timeout:
                log.errorf("unexpected error reading tcp: %s", ex)
				err = .Unexpected_EOF
			case .Not_Socket:
				err = .Unknown
			}
		case nil:
			err = .None
		case:
			assert(false, "recv_tcp only returns TCP_Recv_Error or nil")
		}
		return
	},
}
