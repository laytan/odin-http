//+private
package http

import "core:bufio"
import "core:intrinsics"
import "core:net"

import "nbio"

Scan_Callback :: #type proc(user_data: rawptr, token: string, err: bufio.Scanner_Error)
Split_Proc    :: #type proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool)

scan_lines :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	return bufio.scan_lines(data, at_eof)
}

scan_num_bytes :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	assert(split_data != nil)
	n := int(uintptr(split_data))
	assert(n >= 0)

	if at_eof && len(data) < n {
		return
	}

	if len(data) < n {
		return
	}

	return n, data[:n], nil, false
}

// A callback based scanner over the connection based on nbio.
Scanner :: struct #no_copy {
	connection:                   ^Connection,
	split:                        Split_Proc,
	split_data:                   rawptr,
	buf:                          [dynamic]byte,
	max_token_size:               int,
	start:                        int,
	end:                          int,
	token:                        []byte,
	_err:                         bufio.Scanner_Error,
	consecutive_empty_reads:      int,
	max_consecutive_empty_reads:  int,
	successive_empty_token_count: int,
	done:                         bool,
	could_be_too_short:           bool,
	user_data:                    rawptr,
	callback:                     Scan_Callback,
}

INIT_BUF_SIZE :: 1024
DEFAULT_MAX_CONSECUTIVE_EMPTY_READS :: 128

scanner_init :: proc(s: ^Scanner, c: ^Connection, buf_allocator := context.allocator) {
	s.connection     = c
	s.split          = scan_lines
	s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.buf.allocator  = buf_allocator
}

scanner_destroy :: proc(s: ^Scanner) {
	delete(s.buf)
}

scanner_reset :: proc(s: ^Scanner) {
	s.start                        = 0
	s.end                          = 0
	s.split                        = scan_lines
	s.split_data                   = nil
	s.max_token_size               = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.token                        = nil
	s._err                         = nil
	s.consecutive_empty_reads      = 0
	s.max_consecutive_empty_reads  = DEFAULT_MAX_CONSECUTIVE_EMPTY_READS
	s.successive_empty_token_count = 0
	s.done                         = false
	s.could_be_too_short           = false
}

scanner_scan :: proc(
	s: ^Scanner,
	user_data: rawptr,
	callback: proc(user_data: rawptr, token: string, err: bufio.Scanner_Error),
) {
	set_err :: proc(s: ^Scanner, err: bufio.Scanner_Error) {
		switch s._err {
		case nil, .EOF:
			s._err = err
		}
	}

	if s.done {
		callback(user_data, "", .EOF)
		return
	}

	// Check if a token is possible with what is available
	// Allow the split procedure to recover if it fails
	if s.start < s.end || s._err != nil {
		advance, token, err, final_token := s.split(s.split_data, s.buf[s.start:s.end], s._err != nil)
		if final_token {
			s.token = token
			s.done = true
			callback(user_data, "", .EOF)
			return
		}
		if err != nil {
			set_err(s, err)
			callback(user_data, "", s._err)
			return
		}

		// Do advance
		if advance < 0 {
			set_err(s, .Negative_Advance)
			callback(user_data, "", s._err)
			return
		}
		if advance > s.end - s.start {
			set_err(s, .Advanced_Too_Far)
			callback(user_data, "", s._err)
			return
		}
		s.start += advance

		s.token = token
		if s.token != nil {
			if s._err == nil || advance > 0 {
				s.successive_empty_token_count = 0
			} else {
				s.successive_empty_token_count += 1

				if s.max_consecutive_empty_reads <= 0 {
					s.max_consecutive_empty_reads = DEFAULT_MAX_CONSECUTIVE_EMPTY_READS
				}
				if s.successive_empty_token_count > s.max_consecutive_empty_reads {
					set_err(s, .No_Progress)
					callback(user_data, "", s._err)
					return
				}
			}

			s.consecutive_empty_reads = 0
			s.callback = nil
			s.user_data = nil
			callback(user_data, string(token), s._err)
			return
		}
	}

	// If an error is hit, no token can be created
	if s._err != nil {
		s.start = 0
		s.end = 0
		callback(user_data, "", s._err)
		return
	}

	could_be_too_short := false

	// Resize the buffer if full
	if s.end == len(s.buf) {
		if s.max_token_size <= 0 {
			s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		}

		if s.end - s.start >= s.max_token_size {
			set_err(s, .Too_Long)
			callback(user_data, "", s._err)
			return
		}

		// overflow check
		new_size := INIT_BUF_SIZE
		if len(s.buf) > 0 {
			overflowed: bool
			if new_size, overflowed = intrinsics.overflow_mul(len(s.buf), 2); overflowed {
				set_err(s, .Too_Long)
				callback(user_data, "", s._err)
				return
			}
		}

		old_size := len(s.buf)
		resize(&s.buf, new_size)

		could_be_too_short = old_size >= len(s.buf)

	}

	// Read data into the buffer
	s.consecutive_empty_reads += 1
	s.user_data = user_data
	s.callback = callback
	s.could_be_too_short = could_be_too_short

	assert_has_td()
	// TODO: some kinda timeout on this.
	nbio.recv(&td.io, s.connection.socket, s.buf[s.end:len(s.buf)], s, scanner_on_read)
}

scanner_on_read :: proc(s_: rawptr, n: int, _: Maybe(net.Endpoint), e: net.Network_Error) {
	s := cast(^Scanner)s_

	defer scanner_scan(s, s.user_data, s.callback)

	if e != nil {
		#partial switch ee in e {
		case net.TCP_Recv_Error:
			#partial switch ee {
			case .Connection_Closed, net.TCP_Recv_Error(9):
				// 9 for EBADF (bad file descriptor) happens when OS closes socket.
				s._err = .EOF
				return
			}
		}

		s._err = .Unknown
		return
	}

	// When n == 0, connection is closed or buffer is of length 0.
	if n == 0 {
		s._err = .EOF
		return
	}

	if n < 0 || len(s.buf) - s.end < n {
		s._err = .Bad_Read_Count
		return
	}

	s.end += n
	if n > 0 {
		s.successive_empty_token_count = 0
		return
	}
	s.consecutive_empty_reads += 1

	if s.max_consecutive_empty_reads <= 0 {
		s.max_consecutive_empty_reads = DEFAULT_MAX_CONSECUTIVE_EMPTY_READS
	}
	if s.consecutive_empty_reads > s.max_consecutive_empty_reads {
		if s.could_be_too_short {
			s._err = .Too_Short
		} else {
			s._err = .No_Progress
		}
		return
	}
}
