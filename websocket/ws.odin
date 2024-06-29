package websocket

import "base:intrinsics"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:io"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

import http ".."

// TODO: `destroy` for fully destroying and shutting down the server.

// Predefined (by the WebSocket RFC) status codes.
// Range `0   ..<1000` is unused.
// Range `1000..<3000` is reserved for use by the WebSocket specification.
// Range `3000..<4000` can be used by libraries, frameworks and applications and have to be registered with IANA.
// Range `4000..<5000` can be used by users for private use between endpoints that agree on a meaning.
Status :: enum u16be {
	// Indicates a normal closure, meaning that the purpose for which the connection was
	// established has been fulfilled.
	Normal = 1000,
	// Indicates that an endpoint is "going away",
	// such as a server going down or browser having navigated away from a page.
	Going_Away = 1001,
	// Indicates that an endpoint is terminating the connection due to a protocol error.
	Protocol_Error = 1002,
	// Indicates that an endpoint is terminating the connection because it has
	// received a type of data it cannot accept (e.g., an endpoint that understands only text
	// data MAY send this if it receives a binary message).
	Invalid_Type = 1003,
	// Indicates no status code was present.
	// NOTE: MUST not be set as a status code in a Close control frame by an endpoint.
	No_Status = 1005,
	// Indicates that the connection was closed abnormally, e.g., without sending or receiving
	// a Close control frame.
	// NOTE: MUST not be set as a status code in a Close control frame by an endpoint.
	Abnormal_Close = 1006,
	// Indicates that an endpoint is terminating the connection because it has received data
	// within a message that was not consistent with the type of the message.
	// (e.g., non-UTF8 data within a text message).
	Inconsistent_Data = 1007,
	// Indicates an endpoint is terminating the connection because it has received a message that
	// violates its policy. This is a generic status code when there is no other more
	// suitable status code (e.g., 1003 or 1009) or if there is a need to hide specific details
	// about the policy.
	Violates_Policy = 1008,
	// Indicates an endpoint is terminating the connection because it has received a message that
	// is too big for it to process.
	Too_Big = 1009,
	// Indicates that a client is terminating the connection because it has expected the server
	// to negotiate one or more extensions, but the server didn't return them in the response
	// message of the WebSocket handshake. The list of extensions that are needed SHOULD appear
	// in the reason part of the Close frame. Note that this status code is not used by the server,
	// because it can fail the WebSocket handshake instead.
	Insufficient_Extension_Support = 1010,
	// Indicates that a server is terminating the connection because it encountered an unexpected
	// condition that prevented it from fulfilling the request.
	Unexpected_Condition = 1011,
	// Indicates that the connection was closed due to a failure to perform a TLS handshake.
	// NOTE: MUST not be set as a status code in a Close control frame by an endpoint.
	TLS_Handshake_Failure = 1015,
}

is_valid_status :: proc(s: Status) -> bool {
	si := u16be(s)

	if si >= 3000 && si < 5000 {
		return true
	}

	#partial switch s {
	case .Normal, .Going_Away, .Protocol_Error, .Invalid_Type, .Inconsistent_Data,
		 .Violates_Policy, .Too_Big, .Insufficient_Extension_Support, .Unexpected_Condition:
		return true
	case:
		return false
	}
}

DEFAULT_MAX_PAYLOAD_BYTES :: mem.Megabyte * 16
DEFAULT_IDLE_TIMEOUT      :: time.Minute  * 5

Options :: struct {
	// Time after a receive will time out and close the connection.
	idle_timeout: time.Duration,
	// Connection is closed when a message comes in that is bigger than this.
	max_payload_bytes: int,
}

Message_Type :: enum {
	Text   = 1,
	Binary = 2,
}

// WebSocket :: struct {
// 	opts:       Options,
// 	on_message: proc(w: ^WebSocket, type: Message_Type, message: []byte),
// 	on_open:    proc(w: ^WebSocket),
// 	on_close:   proc(w: ^WebSocket, code: Status, reason: []byte),
// 	user:       rawptr,
// }
//
// send :: proc(w: ^WebSocket, type: Message_Type, message: []byte) {
// }
//
// close :: proc(w: ^WebSocket, code: Status) {
// }

// A WebSocket server.
//
// Upgrade HTTP connection onto the control of this server by using the `upgrade` procedure.
//
// The server is intended to be usable over multiple threads.
// Note that the connections are not, they should be used by one thread at a time, which under
// normal conditions will be the case.
Server :: struct {
	opts:       Options,
	on_message: proc(s: ^Server, c: Connection, user: rawptr, type: Message_Type, message: []byte),
	on_open:    proc(s: ^Server, c: Connection, user: rawptr),
	on_close:   proc(s: ^Server, c: Connection, user: rawptr, code: Status, reason: []byte),
	user:       rawptr,

	// Allocator used for the connections, connection list, free list, and for individual
	// connections that receive fragmented messages (they need to be buffered & concatenated).
	allocator:  mem.Allocator,

	// Private fields:

	// TODO: why are these pointers, we are using handles?

	conns:    [dynamic]^_Connection,
	conns_mu: sync.RW_Mutex,

	free_list:    [dynamic]^_Connection,
	free_list_mu: sync.Mutex,
}

// Iterate over the connections.
connections_iter :: proc(s: ^Server, i: ^int) -> (Connection, bool) {
	sync.shared_guard(&s.conns_mu)

	for {
		if i^ >= len(s.conns) {
			break
		}

		defer i^ += 1

		c := s.conns[i^]
		if c.state != .Open { continue }
		return c.handle, true
	}

	return INVALID_CONNECTION, false
}

// We are using a handle based system so we know when either the user or this code has an outdated
// connection handle, this can happen when IO is queued on a connection, and then it is closed,
// if the IO then completes we have to know if we should be sending things back over the
// connection.
Connection :: struct {
	idx: u32,
	gen: u32,
}

// Send a UTF-8 encoded text message.
send_text :: proc(s: ^Server, ch: Connection, text: string, loc := #caller_location) -> bool {
	if c, has_c := get_conn(s, ch); has_c {
		_send(c, .Text, transmute([]byte)text) or_return
		return true
	}

	log.infof("[ws] send_text called on closed/outdated connection, ignoring", location=loc)
	return false
}

// Send a binary payload.
send_binary :: proc(s: ^Server, ch: Connection, binary: []byte, loc := #caller_location) -> bool {
	if c, has_c := get_conn(s, ch); has_c {
		_send(c, .Binary, binary) or_return
		return true
	}

	log.infof("[ws] send_binary called on closed/outdated connection, ignoring", location=loc)
	return false
}

// Close the connection.
close :: proc(s: ^Server, ch: Connection, status: Status = .Normal, reason: string = "") {
	if c, has_c := get_conn(s, ch); has_c {
		initiate_close(c, status, reason)
	}
}

Stream_State :: enum {
	Nothing_Sent,
	Sending,
	Done,
}

// A buffered stream/writer for WebSocket connections.
Stream :: struct {
	s:           ^Server,
	gen:         int,
	c:           ^_Connection,
	type:        Message_Type,
	state:       Stream_State,
	buf:         [dynamic]byte,

	// 125 bytes is the amount that fits in a frame without encoding extra bytes for the size,
	// seems like a good default.
	default_buf: [125]byte,
}

// Returns an `io.Writer` that writes directly to the WebSocket connection (wrap with `bufio.Writer` to buffer).
// Calling `io.flush`, `io.Destroy`, or `io.Close` will end the message, not the connection.
// NOTE: You can not write other messages while the stream is in-progress (not flushed/destroyed/closed).
init_stream :: proc(stream: ^Stream, s: ^Server, ch: Connection, type: Message_Type = .Text, buf: []byte = nil) -> io.Stream {
	stream.s     = s
	stream.state = .Nothing_Sent
	stream.type  = type

	if c, has_c := get_conn(s, ch); has_c {
		stream.c = c
		stream.gen = c.handle.gen
	}

	if buf == nil {
		stream.buf = slice.into_dynamic(stream.default_buf[:])
	} else {
		stream.buf = slice.into_dynamic(buf)
	}

	stream_proc :: proc(stream: rawptr, mode: io.Stream_Mode, data: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
		stream := (^Stream)(stream)

		if stream.c == nil || stream.c.handle.gen != stream.gen {
			return 0, .Invalid_Write
		}

		switch mode {
		case .Write:
			opcode: Opcode
			switch stream.state {
			case .Done:
				stream.state = .Nothing_Sent
				fallthrough
			case .Nothing_Sent:
				opcode = Opcode(stream.type)
			case .Sending:
				opcode = .Continuation
			case:
				unreachable()
			}

			if len(stream.buf) + len(data) > cap(stream.buf) {
				stream.state = .Sending

				if !_send(stream.c, opcode, stream.buf[:], fin=false) {
					return 0, .Invalid_Write
				}

				clear(&stream.buf)

				if len(data) > cap(stream.buf) {
					if !_send(stream.c, opcode, data, fin=false) {
						return 0, .Invalid_Write
					}
				} else {
					append(&stream.buf, ..data)
				}
			} else {
				append(&stream.buf, ..data)
			}

			return i64(len(data)), nil

		case .Close, .Flush, .Destroy:
			switch stream.state {
			case .Done:
				return 0, nil

			case .Sending, .Nothing_Sent:
				opcode := Opcode(stream.type) if stream.state == .Nothing_Sent else .Continuation
				if !_send(stream.c, opcode, stream.buf[:], fin=true) {
					return 0, .Invalid_Write
				}

				stream.state = .Done
				return 0, nil

			case:
				unreachable()
			}

		case .Query:
			return io.query_utility({ .Close, .Flush, .Destroy, .Write, .Query })
		case: fallthrough
		case .Read, .Seek, .Size, .Read_At, .Write_At:
			return 0, .Empty
		}
	}

	return {
		data      = stream,
		procedure = stream_proc,
	}
}

Upgrade_Error :: enum {
	None,

	Missing_Upgrade_Header,
	Invalid_Upgrade_Header,
	Missing_Connection_Header,
	Invalid_Connection_Header,
	Missing_Key_Header,
	Invalid_Key_Header,
	Missing_Version_Header,

	// Returned when the client sent a version we don't support,
	// the `sec-websocket-version` header will have been set so the client can use that to
	// negotiate a proper version and redo the handshake.
	Version_Negotiation,
}

// Tries to upgrade a connection to be on the WebSocket server.
// Returns any error during this process, modifying the given HTTP response in the process.
// NOTE: User must call `http.respond` themselves.
upgrade :: proc(s: ^Server, req: ^http.Request, res: ^http.Response, user: rawptr) -> Upgrade_Error {
	http.response_status(res, .Bad_Request)

	upgrade, has_upgrade := http.headers_get_unsafe(req.headers, "upgrade")
	if !has_upgrade {
		return .Missing_Upgrade_Header
	}
	if !ascii_case_insensitive_eq(upgrade, "websocket") {
		return .Invalid_Upgrade_Header
	}

	connection, has_connection := http.headers_get_unsafe(req.headers, "connection")
	if !has_connection {
		return .Missing_Connection_Header
	}
	if !ascii_case_insensitive_eq(connection, "upgrade") {
		return .Invalid_Connection_Header
	}

	key, has_key := http.headers_get_unsafe(req.headers, "sec-websocket-key")
	if !has_key {
		return .Missing_Key_Header
	}
	if base64.decoded_len(key) != 16 {
		return .Invalid_Key_Header
	}

	decoded_key: [16]byte = ---
	decoded_key_builder := strings.builder_from_bytes(decoded_key[:])
	decoded_key_writer  := strings.to_stream(&decoded_key_builder)
	if base64.decode_into(decoded_key_writer, key) != nil {
		return .Invalid_Key_Header
	}

	ws_version, has_ws_version := http.headers_get_unsafe(req.headers, "sec-websocket-version")
	if !has_ws_version {
		return .Missing_Version_Header
	}
	if ws_version != "13" {
		http.headers_set_unsafe(&res.headers, "sec-websocket-version", "13")
		return .Version_Negotiation
	}

	http.response_status(res, .Switching_Protocols)

	http.headers_set_unsafe(&res.headers, "upgrade", "websocket")
	http.headers_set_unsafe(&res.headers, "connection", "upgrade")

	{
		accept_hash: [20]byte = ---
		assert(hash.DIGEST_SIZES[.Insecure_SHA1] == 20)

		ctx: hash.Context
		hash.init(&ctx, .Insecure_SHA1)
		hash.update(&ctx, transmute([]byte)key)
		hash.update(&ctx, transmute([]byte)GUID)
		hash.final(&ctx, accept_hash[:])

		accept := base64.encode(accept_hash[:], allocator=context.temp_allocator)
		http.headers_set_unsafe(&res.headers, "sec-websocket-accept", accept)
	}

	c := new_conn(s, res._conn)
	c.ud = user

	res._conn.ud = c

	res.on_sent_ud = s
	res.on_sent    = handle_connection
	return .None
}

