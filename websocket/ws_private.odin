//+private
package websocket

import "base:intrinsics"
import "core:bufio"
import "core:encoding/endian"
import "core:io"
import "core:log"
import "core:mem"
import "core:net"
import "core:sync"
import "core:time"
import "core:unicode/utf8"
import "core:slice"

import http ".."
import nbio "../nbio/poly"

// GUID for the WebSocket protocol.
@(rodata)
GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Magic frame header length indicates length of payload is the following 2 bytes (as a u16be).
LEN_2_BYTES :: 126

// Magic frame header length indicates length of payload is the following 8 bytes (as a u64be).
LEN_8_BYTES :: 127

@(private)
INVALID_CONNECTION :: Connection(max(u64))

new_conn :: proc(s: ^Server, hc: ^http.Connection) -> ^_Connection {
	{
		sync.guard(&s.free_list_mu)
		if conn, has_conn := pop_safe(&s.free_list); has_conn {
			conn.http     = hc
			conn.state    = .Opening
			return conn
		}
	}

	conn := new(_Connection)

	conn.fragmented_buf.allocator = s.allocator

	conn.s        = s
	conn.http     = hc
	conn.state    = .Opening

	sync.guard(&s.conns_mu)
	conn.handle = Connection{
		idx = len(s.conns),
		gen = 1,
	}
	append(&s.conns, conn)
	return conn
}

get_conn :: proc(s: ^Server, c: Connection) -> (conn: ^_Connection, ok: bool) {
	if c == INVALID_CONNECTION {
		return nil, false
	}

	idx := c.idx
	sync.shared_guard(&s.conns_mu)
	if idx >= len(s.conns) {
		return nil, false
	}
	conn = s.conns[idx]
	ok = conn.handle == c
	return
}

free_conn :: proc(c: ^_Connection) {
	c.handle.gen += 1
	c.http  = nil
	c.frame = {}
	c.state = .Closed
	c.ud    = nil
	c.pending = 0
	c.fragmented_op = nil
	clear(&c.fragmented_buf)

	sync.guard(&c.s.free_list_mu)
	append(&c.s.free_list, c)
}

// Every activity, change timeout to `now` + `idle_timeout`.
// Every IO interaction, set a timeout of the duration until then.
// On IO callback, check if it was a timeout error, if it was, and if the timeout is still the same, close.

Connection_State :: enum {
	Opening,
	Open,
	Closing,
	Closed,
}

_Connection :: struct {
	handle:   Connection,
	s:        ^Server,
	http:     ^http.Connection,
	frame:    Frame,
	state:    Connection_State,
	ud:       rawptr,
	pending:  int,
	activity: time.Time,

	fragmented_op:  Opcode,
	fragmented_buf: [dynamic]byte,
}

Opcode :: enum u8 {
	Continuation,
	Text,
	Binary,
	Close = 8,
	Ping,
	Pong,
}

Frame_Header :: bit_field u16 {
	opcode:       Opcode | 4,
	rsv3:         bool   | 1,
	rsv2:         bool   | 1,
	rsv1:         bool   | 1,
	fin:          bool   | 1,
	hpayload_len: u8     | 7,
	masked:       bool   | 1,
}

Frame :: struct {
	using header: Frame_Header,
	payload_len:  u64,
	mask:         [4]byte,
	payload_data: []byte,
}

recv_message :: proc(c: ^_Connection) {
	scanner := &c.http.scanner
	http.scanner_reset(scanner)

	c.s.opts.max_payload_bytes = DEFAULT_MAX_PAYLOAD_BYTES if c.s.opts.max_payload_bytes == 0 else c.s.opts.max_payload_bytes
	c.s.opts.idle_timeout      = DEFAULT_IDLE_TIMEOUT if c.s.opts.idle_timeout == 0 else c.s.opts.idle_timeout

	scanner.max_token_size = c.s.opts.max_payload_bytes
	scanner.timeout        = c.s.opts.idle_timeout

	scanner.split      = http.scan_num_bytes
	scanner.split_data = rawptr(uintptr(size_of(Frame_Header)))

	http.scanner_scan(&c.http.scanner, c.s, c.handle, on_frame_header)

	on_frame_header :: proc(s: ^Server, ch: Connection, token: string, err: bufio.Scanner_Error) {
		c, has_c := get_conn(s, ch)
		if !has_c do return

		buf := transmute([]byte)token

		// TODO: non-EOF should send a close frame, also Too_Big could be returned here on some errors.
		if !handle_scanner_err(c, err) {
			return
		}

		#assert(size_of(Frame_Header) == size_of(u16))
		assert(len(buf) == 2)
		c.frame.header = Frame_Header((^u16)(raw_data(buf))^)

		if c.frame.rsv1 || c.frame.rsv2 || c.frame.rsv3 {
			initiate_close(c, .Protocol_Error, "reserved bit(s) set")
			return
		}

		if !c.frame.masked {
			initiate_close(c, .Protocol_Error, "unmasked data")
			return
		}

		length := c.frame.hpayload_len
		opcode := c.frame.opcode
		if length > 125 && (opcode != .Text && opcode != .Binary && opcode != .Continuation) {
			initiate_close(c, .Protocol_Error, "control frame with a payload over 125 bytes long")
			return
		}

		switch length {
		case LEN_2_BYTES:
			c.http.scanner.split_data = rawptr(uintptr(size_of(u16)))
			http.scanner_scan(&c.http.scanner, s, ch, on_payload_len)
		case LEN_8_BYTES:
			c.http.scanner.split_data = rawptr(uintptr(size_of(u64)))
			http.scanner_scan(&c.http.scanner, s, ch, on_payload_len)
		case:
			assert(length <= 125)
			on_payload_len(s, ch, "", nil)
		}
	}

	on_payload_len :: proc(s: ^Server, ch: Connection, token: string, err: bufio.Scanner_Error) {
		c, has_c := get_conn(s, ch)
		if !has_c do return

		buf := transmute([]byte)token

		if !handle_scanner_err(c, err) {
			return
		}

		switch len(buf) {
		case 8: c.frame.payload_len = endian.unchecked_get_u64be(buf)
		case 2: c.frame.payload_len = u64(endian.unchecked_get_u16be(buf))
		case 0: c.frame.payload_len = u64(c.frame.hpayload_len)
		case:   unreachable()
		}

		if c.frame.payload_len > u64(max(int)) || int(c.frame.payload_len) > c.http.scanner.max_token_size {
			initiate_close(c, .Too_Big)
			return
		}

		assert(c.frame.masked)

		#assert(size_of(uintptr) == size_of(u64))

		size := size_of(c.frame.mask) + c.frame.payload_len
		c.http.scanner.split_data = rawptr(uintptr(size))

		http.scanner_scan(&c.http.scanner, s, ch, on_masked_payload)
	}

	on_masked_payload :: proc(s: ^Server, ch: Connection, token: string, err: bufio.Scanner_Error) {
		c, has_c := get_conn(s, ch)
		if !has_c do return

		buf := transmute([]byte)token

		if !handle_scanner_err(c, err) {
			return
		}

		assert(u64(len(buf)) == size_of(u32) + c.frame.payload_len)
		#no_bounds_check {
			c.frame.mask = (^[4]byte)(raw_data(buf))^
			c.frame.payload_data = buf[4:]

			mask := transmute(u32)c.frame.mask
			u32s := slice.reinterpret([]u32, c.frame.payload_data)
			for &part in u32s {
				part = part ~ mask
			}
			for &b, i in c.frame.payload_data[len(u32s)*size_of(u32):] {
				b = b ~ c.frame.mask[i % 4]
			}
		}

		log.debugf("[%i][ws] <- %v of %m", c.http.socket, c.frame.opcode, c.frame.payload_len)

		opcode := c.frame.opcode
		if !c.frame.fin && (opcode != .Text && opcode != .Binary && opcode != .Continuation) {
			initiate_close(c, .Protocol_Error, "fin bit set on control frame")
			return
		}

		switch opcode {
		case .Close:
			code := Status.No_Status
			reason: []byte
			if c.frame.payload_len == 1 {
				initiate_close(c, .Protocol_Error, "invalid payload data size of 1 for close frame")
				return
			} else if c.frame.payload_len >= 2 {
				code   = Status((^u16be)(raw_data(c.frame.payload_data))^)
				reason = c.frame.payload_data[2:]

				if !is_valid_status(code) {
					initiate_close(c, .Protocol_Error, "invalid close status code")
					return
				}
			}

			if !utf8.valid_string(string(reason)) {
				initiate_close(c, .Inconsistent_Data, "close frame with invalid UTF-8 reason")
				return
			}

			switch c.state {
			case .Closing:
				finish_close(c, code, reason)

			case .Open:
				if c.s.on_close != nil {
					c.s.on_close(s, ch, c.ud, code, reason)
				}

				_send(c, .Close, c.frame.payload_data, proc(c: ^_Connection) {
					finish_close(c, nil, nil, invoke_callback=false)
				})

			case: fallthrough
			case .Closed, .Opening:
				log.panicf("[%i][ws] got close frame, but connection is in invalid state: %v", c.http.socket, c.state)
			}

			return

		case .Text, .Binary:
			switch c.state {
			case .Open:
				#assert(int(Opcode.Text)   == int(Message_Type.Text))
				#assert(int(Opcode.Binary) == int(Message_Type.Binary))

				if c.s.on_message == nil {
					log.panicf("[ws] server has no on_message callback set!")
				}

				if c.fragmented_op != nil {
					initiate_close(c, .Protocol_Error, "non-fragmented frame, expected a fragmented frame")
					return
				}

				if !c.frame.fin {
					if c.fragmented_op != .Continuation {
						initiate_close(c, .Protocol_Error, "fragmented frame while one is in progress")
						return
					}

					c.fragmented_op = opcode
					clear(&c.fragmented_buf)
					append(&c.fragmented_buf, ..c.frame.payload_data)
					log.debugf("[%i][ws] start of fragmented %v message", c.http.socket, opcode)
				} else {
					// TODO: a faster `utf8.valid_string`.
					if opcode == .Text && !utf8.valid_string(string(c.frame.payload_data)) {
						initiate_close(c, .Inconsistent_Data, "invalid UTF-8 text")
						return
					}

					c.s.on_message(c.s, ch, c.ud, Message_Type(opcode), c.frame.payload_data)
				}

			case .Closing:
				log.infof("[%i][ws] got %v frame, but connection is closing, ignoring", c.http.socket, opcode)

			case: fallthrough
			case .Closed, .Opening:
				log.panicf("[%i][ws] got %v frame, but connection is in invalid state: %v", c.http.socket, opcode, c.state)
			}

		case .Ping:
			_send(c, .Pong, c.frame.payload_data)

		case .Pong:
			// TODO: Do nothing, just update idle time, like the others.

		case .Continuation:
			if c.fragmented_op != .Text && c.fragmented_op != .Binary {
				initiate_close(c, .Protocol_Error, "continuation frame with no fragmented message in progress")
				return
			}

			if u64(len(c.fragmented_buf)) + c.frame.payload_len > u64(s.opts.max_payload_bytes) {
				initiate_close(c, .Too_Big)
				return
			}

			append(&c.fragmented_buf, ..c.frame.payload_data)
			log.debugf("[%i][ws] continuation of %m", c.http.socket, c.frame.payload_len)

			if c.frame.fin {
				log.debugf("[%i][ws] fragmented message complete", c.http.socket)

				// TODO: a faster `utf8.valid_string`.
				if c.fragmented_op == .Text && !utf8.valid_string(string(c.fragmented_buf[:])) {
					initiate_close(c, .Inconsistent_Data, "invalid UTF-8 text")
					return
				}

				c.s.on_message(c.s, ch, c.ud, Message_Type(c.fragmented_op), c.fragmented_buf[:])
				c.fragmented_op = .Continuation
			}
		case:
			initiate_close(c, .Protocol_Error, "unknown opcode")
			return
		}

		recv_message(c)
	}
}

handle_connection :: proc(c: ^http.Connection, s: rawptr) {
	s := (^Server)(s)
	wc := (^_Connection)(c.ud)

	switch wc.state {
	case: fallthrough
	case .Open, .Closing, .Closed:
		log.panicf("[%i][ws] connection opened but in invalid state: %v", c.socket, c.state)

	case .Opening:
		wc.state = .Open

		if s.on_open != nil {
			s.on_open(s, wc.handle, wc.ud)
		}

		recv_message(wc)
	}
}

_send :: proc(c: ^_Connection, opcode: Opcode, data: []byte, cb: proc(^_Connection) = nil, fin := true) -> bool {
	switch c.state {
	case: fallthrough
	case .Opening, .Closed, .Closing:
		log.warnf("[%i][ws] sending while %v, ignoring", c.http.socket, c.state)
		return false
	case .Open:
		if opcode == .Close {
			c.state = .Closing
		}
	}

	header := Frame_Header{
		opcode = opcode,
		fin    = fin,
	}

	length := size_of(Frame_Header) + len(data)

	switch {
	case len(data) > int(max(u16)):
		header.hpayload_len = LEN_8_BYTES
		length += size_of(u64)
	case len(data) > 125:
		header.hpayload_len = LEN_2_BYTES
		length += size_of(u16)
	case:
		header.hpayload_len = u8(len(data))
	}

	context.temp_allocator = http.connection_temp_allocator(c.http)
	buf := make([]byte, length, context.temp_allocator)

	n := copy(buf, mem.ptr_to_bytes(&header))

	switch {
	case len(data) > int(max(u16)):
		endian.unchecked_put_u64be(buf[n:], u64(len(data)))
		n += size_of(u64)
	case len(data) > 125:
		endian.unchecked_put_u16be(buf[n:], u16(len(data)))
		n += size_of(u16)
	}

	n += copy(buf[n:], data)

	assert(n == length)

	log.debugf("[%i][ws] -> %v of %m", c.http.socket, opcode, len(data))

	c.pending += 1
	nbio.send_all(&http.td.io, c.http.socket, buf, c.s, c.handle, cb, on_sent)

	on_sent :: proc(s: ^Server, ch: Connection, cb: proc(^_Connection), sent: int, err: net.Network_Error) {
		c, has_c := get_conn(s, ch)
		if !has_c do return

		log.debugf("[%i][ws] sent %m", c.http.socket, sent)

		if !handle_net_err(c, err) {
			return
		}

		c.pending -= 1
		assert(c.pending >= 0)
		if c.pending == 0 {
			free_all(context.temp_allocator)
		}

		if cb != nil {
			cb(c)
		}
	}

	return true
}

initiate_close :: proc(c: ^_Connection, status: Status, reason := "") {
	status := status

	if status == .Too_Big {
		log.infof("[%i][ws] initiating close handshake, payload too big, max payload size configured is %m", c.http.socket, c.s.opts.max_payload_bytes)
	} else {
		log.infof("[%i][ws] initiating close handshake: %v %s", c.http.socket, status, reason)
	}

	switch c.state {
	case .Closing: // NOTE: might want to just close the full connection at this point.
		log.infof("[%i][ws] asked to initiate close handshake but already closing")
		return

	case: fallthrough
	case .Closed, .Opening:
		log.panicf("[%i][ws] asked to initiate close handshake from invalid state: %v", c.state)

	case .Open:
		#assert(intrinsics.type_core_type(Status) == u16be)

		#partial switch status {
		// Don't wait for a response.
		case .Protocol_Error:
			if c.s.on_close != nil {
				c.s.on_close(c.s, c.handle, c.ud, status, nil)
			}

			_send(c, .Close, mem.ptr_to_bytes(&status), proc(c: ^_Connection) {
				finish_close(c, nil, nil, invoke_callback=false)
			})

		// Wait for a response.
		case:
			_send(c, .Close, mem.ptr_to_bytes(&status))
			recv_message(c)
		}
	}
}

finish_close :: proc(c: ^_Connection, status: Status, reason: []byte = nil, invoke_callback := true) {
	c.state = .Closed
	if invoke_callback && c.s.on_close != nil {
		c.s.on_close(c.s, c.handle, c.ud, status, reason)
	}
	http._connection_close(c.http)
	free_conn(c)
}

handle_net_err :: proc(c: ^_Connection, e: net.Network_Error) -> bool {
	if intrinsics.expect(e == nil, true) {
		return true
	}

	#partial switch ee in e {
	case net.TCP_Recv_Error:
		#partial switch ee {
		case .Connection_Closed, net.TCP_Recv_Error(9):
			// 9 for EBADF (bad file descriptor) happens when OS closes socket.
			return handle_scanner_err(c, .EOF)
		case .Timeout:
			return handle_scanner_err(c, .No_Progress)
		}
	}

	log.errorf("[%i][ws] unexpected net err: %v", e)
	return handle_scanner_err(c, .Unknown)
}

handle_scanner_err :: proc(c: ^_Connection, err: bufio.Scanner_Error) -> bool {
	if intrinsics.expect(err == nil, true) {
		return true
	}

	switch e in err {
	case bufio.Scanner_Extra_Error:
		switch e {
		case .None:
			unreachable()

		case: fallthrough
		case .Negative_Advance, .Advanced_Too_Far, .Bad_Read_Count:
			log.panicf("[%i][ws] unexpected recv error: %v", c.http.socket, e)

		case .Too_Long:
			initiate_close(c, .Too_Big)
			return false

		case .Too_Short:
			log.infof("[%i][ws] %v on recv, initiating close handshake", c.http.socket, e)
			initiate_close(c, .Violates_Policy)
			return false
		}

	case io.Error:
		switch e {
		case .None:
			unreachable()

		case .EOF, .Unexpected_EOF:
			log.infof("[%i][ws] %v on recv, assuming client closed connection abruptly", c.http.socket, e)
			finish_close(c, .Abnormal_Close)
			return false

		case .No_Progress:
			// NOTE: we could (if needed) keep track of last activity time on the connection
			// and check if it actually did cross the idle timeout or not here.

			log.infof("[%i][ws] No_Progress/Timeout on recv, initiating close handshake", c.http.socket)
			initiate_close(c, .Normal, "connection timed out")
			return false

		case .Unknown:
			log.infof("[%i][ws] %v on recv, initiating close handshake", c.http.socket, e)
			initiate_close(c, .Violates_Policy)
			return false

		case: fallthrough
		case .Invalid_Whence, .Invalid_Offset, .Invalid_Unread, .Invalid_Write,
			 .Negative_Read, .Negative_Write, .Negative_Count,
			 .Short_Write, .Empty, .Short_Buffer, .Buffer_Full:
			log.panicf("[%i][ws] unexpected recv error: %v", c.http.socket, e)
		}

	case:
		unreachable()
	}

	return false
}

// NOTE: `to` is assumed lowercase!
ascii_case_insensitive_eq :: proc(cmp: string, to: string) -> bool {
	if cmp == to           do return true
	if len(cmp) != len(to) do return false

	to := to
	for c, i in transmute([]byte)cmp {
		switch c {
		case 'A'..='Z':
			DIFF :: 'a' - 'A'
			if c + DIFF != to[i] do return false
		case:
			if c != to[i] do return false
		}
	}

	return true
}
