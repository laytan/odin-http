//+private
package http

import "core:bufio"
import "core:intrinsics"
import "core:net"

import "nbio"

Scan_Callback :: proc(user_data: rawptr, token: []byte, err: bufio.Scanner_Error)

// A callback based scanner over the connection based on nbio.
Scanner :: struct {
	connection:                   ^Connection,
	split:                        bufio.Split_Proc,
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
	s.connection = c
	s.split = bufio.scan_lines
	s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.buf.allocator = buf_allocator
}

scanner_destroy :: proc(s: ^Scanner) {
	delete(s.buf)
}

scanner_scan :: proc(
	s: ^Scanner,
	user_data: rawptr,
	callback: proc(user_data: rawptr, token: []byte, err: bufio.Scanner_Error),
) {
	set_err :: proc(s: ^Scanner, err: bufio.Scanner_Error) {
		switch s._err {
		case nil, .EOF:
			s._err = err
		}
	}

	if s.done {
		callback(user_data, nil, .EOF)
		return
	}

	// Check if a token is possible with what is available
	// Allow the split procedure to recover if it fails
	if s.start < s.end || s._err != nil {
		advance, token, err, final_token := s.split(s.buf[s.start:s.end], s._err != nil)
		if final_token {
			s.token = token
			s.done = true
			callback(user_data, nil, .EOF)
			return
		}
		if err != nil {
			set_err(s, err)
			callback(user_data, nil, s._err)
			return
		}

		// Do advance
		if advance < 0 {
			set_err(s, .Negative_Advance)
			callback(user_data, nil, s._err)
			return
		}
		if advance > s.end - s.start {
			set_err(s, .Advanced_Too_Far)
			callback(user_data, nil, s._err)
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
					callback(user_data, nil, s._err)
					return
				}
			}

			s.consecutive_empty_reads = 0
			s.callback = nil
			s.user_data = nil
			callback(user_data, token, s._err)
			return
		}
	}

	// If an error is hit, no token can be created
	if s._err != nil {
		s.start = 0
		s.end = 0
		callback(user_data, nil, s._err)
		return
	}

	// More data must be required to be read
	if s.start > 0 && (s.end == len(s.buf) || s.start > len(s.buf) / 2) {
		copy(s.buf[:], s.buf[s.start:s.end])
		s.end -= s.start
		s.start = 0
	}

	could_be_too_short := false

	// Resize the buffer if full
	if s.end == len(s.buf) {
		if s.max_token_size <= 0 {
			s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		}
		if len(s.buf) >= s.max_token_size {
			set_err(s, .Too_Long)
			callback(user_data, nil, s._err)
			return
		}
		// overflow check
		new_size := INIT_BUF_SIZE
		if len(s.buf) > 0 {
			overflowed: bool
			if new_size, overflowed = intrinsics.overflow_mul(len(s.buf), 2); overflowed {
				set_err(s, .Too_Long)
				callback(user_data, nil, s._err)
				return
			}
		}

		old_size := len(s.buf)
		new_size = min(new_size, s.max_token_size)
		resize(&s.buf, new_size)
		s.end -= s.start
		s.start = 0

		could_be_too_short = old_size >= len(s.buf)

	}

	// Read data into the buffer
	s.consecutive_empty_reads += 1
	s.user_data = user_data
	s.callback = callback
	s.could_be_too_short = could_be_too_short

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
