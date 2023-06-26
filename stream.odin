package http

import "core:io"
import "core:net"
import "core:log"
import "core:c"

import "openssl"

// Wraps a tcp socket with a stream.
tcp_stream :: proc(sock: net.TCP_Socket) -> (s: io.Stream) {
	s.data = rawptr(uintptr(sock))
	s.procedure = _socket_stream_proc
	return s
}

@(private)
_socket_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read})
	case .Read:
		sock := net.TCP_Socket(uintptr(stream_data))
		received, recv_err := net.recv_tcp(sock, p)
		n = i64(received)

		#partial switch ex in recv_err {
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
	case:
		err = .Empty
	}
	return
}

ssl_tcp_stream :: proc(sock: ^openssl.SSL) -> (s: io.Stream) {
	s.data = sock
	s.procedure = _ssl_stream_proc
	return s
}

@(private)
_ssl_stream_proc :: proc(
	stream_data: rawptr,
	mode: io.Stream_Mode,
	p: []byte,
	offset: i64,
	whence: io.Seek_From,
) -> (
	n: i64,
	err: io.Error,
) {
	#partial switch mode {
	case .Query:
		return io.query_utility(io.Stream_Mode_Set{.Query, .Read})
	case .Read:
		ssl := cast(^openssl.SSL)stream_data
		ret := openssl.SSL_read(ssl, raw_data(p), c.int(len(p)))
		if ret <= 0 {
			return 0, .Unexpected_EOF
		}

		return i64(ret), nil
	case:
		err = .Empty
	}
	return
}
