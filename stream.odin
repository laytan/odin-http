package http

import "core:io"
import "core:net"
import "core:log"

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
