package http

import "core:io"
import "core:net"
import "core:log"
import "core:c"

import "openssl"

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
			#partial switch ex {
			case .None:
				err = .None
			case .Shutdown, .Not_Connected, .Aborted, .Connection_Closed, .Host_Unreachable, .Timeout:
				log.errorf("unexpected error reading tcp: %s", ex)
				err = .Unexpected_EOF
			case:
				log.errorf("unexpected error reading tcp: %s", ex)
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

ssl_tcp_stream :: proc(sock: ^openssl.SSL) -> (s: io.Stream) {
	s.stream_data = sock
	s.stream_vtable = &_ssl_stream_vtable
	return s
}

@(private)
_ssl_stream_vtable := io.Stream_VTable {
	impl_read = proc(s: io.Stream, p: []byte) -> (n: int, err: io.Error) {
		ssl := cast(^openssl.SSL)s.stream_data
		ret := openssl.SSL_read(ssl, raw_data(p), c.int(len(p)))
		if ret <= 0 {
			return 0, .Unexpected_EOF
		}

		return int(ret), nil
	},
}
