package http

import "core:bytes"
import "core:io"
import "core:log"
import "core:net"
import "core:slice"
import "core:strconv"

import "nbio"

Response :: struct {
	// Add your headers and cookies here directly.
	headers:          Headers,
	cookies:          [dynamic]Cookie,

	// If the response has been sent.
	sent:             bool,

	// NOTE: use `http.response_status` if the response body might have been set already.
	status:           Status,

	// Only for internal usage.
	_conn:            ^Connection,
	// TODO/PERF: with some internal refactoring, we should be able to write directly to the
	// connection (maybe a small buffer in this struct).
	_buf:             bytes.Buffer,
	_heading_written: bool,
}

response_init :: proc(r: ^Response, allocator := context.allocator) {
	r.status             = .Not_Found
	r.cookies.allocator  = allocator
	r._buf.buf.allocator = allocator

	headers_init(&r.headers, allocator)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_bytes :: proc(r: ^Response, byts: []byte, loc := #caller_location) {
	assert(bytes.buffer_length(&r._buf) == 0, "the response body has already been written", loc)
	_response_write_heading(r, len(byts))
	bytes.buffer_write(&r._buf, byts)
}

/*
Prefer the procedure group `body_set`.
*/
body_set_str :: proc(r: ^Response, str: string, loc := #caller_location) {
	// This is safe because we don't write to the bytes.
	body_set_bytes(r, transmute([]byte)str, loc)
}

/*
Sets the response body. After calling this you can no longer add headers to the response.
If, after calling, you want to change the status code, use the `response_status` procedure.

For bodies where you do not know the size or want an `io.Writer`, use the `response_writer_init`
procedure to create a writer.
*/
body_set :: proc{
	body_set_str,
	body_set_bytes,
}

/*
Sets the status code with the safety of being able to do this after writing (part of) the body.
*/
response_status :: proc(r: ^Response, status: Status) {
	if r.status == status do return

	r.status = status

	// If we have already written the heading, we can address the bytes directly to overwrite,
	// this is because of the fact that every status code is of length 3, and because we omit
	// the "optional" reason phrase out of the response.
	if bytes.buffer_length(&r._buf) > 0 {
		OFFSET :: len("HTTP/1.1 ")

		status_int_str := status_string(r.status)
		if len(status_int_str) < 4 {
			status_int_str = "500 "
		} else {
			status_int_str = status_int_str[0:4]
		}

		copy(r._buf.buf[OFFSET:OFFSET + 4], status_int_str)
	}
}

Response_Writer :: struct {
	r:     ^Response,
	// The writer you can write to.
	w:     io.Writer,
	// A dynamic wrapper over the `buffer` given in `response_writer_init`, doesn't allocate.
	buf:   [dynamic]byte,
	// If destroy or close has been called.
	ended: bool,
}

/*
Initialize a writer you can use to write responses. Use the `body_set` procedure group if you have
a string or byte slice.

The buffer can be used to avoid very small writes, like the ones when you use the json package
(each write in the json package is only a few bytes). You are allowed to pass nil which will disable
buffering.

NOTE: You need to call io.destroy to signal the end of the body, OR io.close to send the response.
*/
response_writer_init :: proc(rw: ^Response_Writer, r: ^Response, buffer: []byte) -> io.Writer {
	headers_set_unsafe(&r.headers, "transfer-encoding", "chunked")
	_response_write_heading(r, -1)

	rw.buf = slice.into_dynamic(buffer)
	rw.r   = r

	rw.w = io.Stream{
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			ws :: bytes.buffer_write_string
			write_chunk :: proc(b: ^bytes.Buffer, chunk: []byte) {
				plen := i64(len(chunk))
				if plen == 0 do return

				log.debugf("response_writer chunk of size: %i", plen)

				bytes.buffer_grow(b, 16)
				size_buf := _dynamic_unwritten(b.buf)
				size := strconv.append_int(size_buf, plen, 16)
				_dynamic_add_len(&b.buf, len(size))

				ws(b, "\r\n")
				bytes.buffer_write(b, chunk)
				ws(b, "\r\n")
			}

			rw := (^Response_Writer)(stream_data)
			b := &rw.r._buf

			#partial switch mode {
			case .Flush:
				assert(!rw.ended)

				write_chunk(b, rw.buf[:])
				clear(&rw.buf)
				return 0, nil

			case .Destroy:
				assert(!rw.ended)

				// Write what is left.
				write_chunk(b, rw.buf[:])

				// Signals the end of the body.
				ws(b, "0\r\n\r\n")

				rw.ended = true
				return 0, nil

			case .Close:
				// Write what is left.
				write_chunk(b, rw.buf[:])

				if !rw.ended {
					// Signals the end of the body.
					ws(b, "0\r\n\r\n")
					rw.ended = true
				}

				// Send the response.
				respond(rw.r)
				return 0, nil

			case .Write:
				assert(!rw.ended)

				// No space, first write rw.buf, then check again for space, if still no space,
				// fully write the given p.
				if len(rw.buf) + len(p) > cap(rw.buf) {
					write_chunk(b, rw.buf[:])
					clear(&rw.buf)

					if len(p) > cap(rw.buf) {
						write_chunk(b, p)
					} else {
						append(&rw.buf, ..p)
					}
				} else {
					// Space, append bytes to the buffer.
					append(&rw.buf, ..p)
				}

				return i64(len(p)), .None

			case .Query:
				return io.query_utility({.Write, .Flush, .Destroy, .Close})
			}
			return 0, .Empty
		},
		data = rw,
	}
	return rw.w
}

/*
Writes the response status and headers to the buffer.

This is automatically called before writing anything to the Response.body or before calling a procedure
that sends the response.

You can pass `content_length < 0` to omit the content-length header, note that this header is
required on most responses, but there are things like transfer-encodings that could leave it out.
*/
_response_write_heading :: proc(r: ^Response, content_length: int) {
	if r._heading_written do return
	r._heading_written = true

	ws   :: bytes.buffer_write_string
	conn := r._conn
	b    := &r._buf

	MIN             :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	reserve_size    := MIN + content_length + (AVG_HEADER_SIZE * headers_count(r.headers))
	bytes.buffer_grow(&r._buf, reserve_size)

	// According to RFC 7230 3.1.2 the reason phrase is insignificant,
	// because not doing so (and the fact that a status code is always length 3), we can change
	// the status code when we are already writing a body by just addressing the 3 bytes directly.
	status_int_str := status_string(r.status)
	if len(status_int_str) < 4 {
		status_int_str = "500 "
	} else {
		status_int_str = status_int_str[0:4]
	}

	ws(b, "HTTP/1.1 ")
	ws(b, status_int_str)
	ws(b, "\r\n")

	// Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
	if r.status >= .OK && r.status <= .Internal_Server_Error && !headers_has_unsafe(r.headers, "date") {
		ws(b, "date: ")
		ws(b, server_date(conn.server))
		ws(b, "\r\n")
	}

	if (
		content_length > -1                              &&
		!headers_has_unsafe(r.headers, "content-length") &&
		response_needs_content_length(r, conn) \
	) {
		if content_length == 0 {
			ws(b, "content-length: 0\r\n")
		} else {
			ws(b, "content-length: ")

			assert(content_length < 1000000000000000000 && content_length > -1000000000000000000)
			buf: [20]byte
			ws(b, strconv.itoa(buf[:], content_length))
			ws(b, "\r\n")
		}
	}

	bstream := bytes.buffer_to_stream(b)

	for header, value in r.headers._kv {
		ws(b, header) // already has newlines escaped.
		ws(b, ": ")
		write_escaped_newlines(bstream, value)
		ws(b, "\r\n")
	}

	for cookie in r.cookies {
		cookie_write(bstream, cookie)
		ws(b, "\r\n")
	}

	// Empty line denotes end of headers and start of body.
	ws(b, "\r\n")
}

// Sends the response over the connection.
// Frees the allocator (should be a request scoped allocator).
// Closes the connection or starts the handling of the next request.
@(private)
response_send :: proc(r: ^Response, conn: ^Connection, loc := #caller_location) {
	assert(!r.sent, "response has already been sent", loc)
	r.sent = true

	check_body := proc(res: rawptr, body: Body, err: Body_Error) {
		res := cast(^Response)res
		will_close: bool

		if err != nil {
			// Any read error should close the connection.
			response_status(res, body_error_status(err))
			headers_set_close(&res.headers)
			will_close = true
		}

		response_send_got_body(res, will_close)
	}

	// RFC 7230 6.3: A server MUST read
	// the entire request message body or close the connection after sending
	// its response, since otherwise the remaining data on a persistent
	// connection would be misinterpreted as the next request.
	if !response_must_close(&conn.loop.req, r) {

		// Body has been drained during handling.
		if _, got_body := conn.loop.req._body_ok.?; got_body {
			response_send_got_body(r, false)
		} else {
			body(&conn.loop.req, Max_Post_Handler_Discard_Bytes, r, check_body)
		}

	} else {
		response_send_got_body(r, true)
	}
}

@(private)
response_send_got_body :: proc(r: ^Response, will_close: bool) {
	conn := r._conn

	if will_close {
		if !connection_set_state(r._conn, .Will_Close) do return
	}

	if bytes.buffer_length(&r._buf) == 0 {
		_response_write_heading(r, 0)
	}

	buf := bytes.buffer_to_bytes(&r._buf)
	nbio.send_all(&td.io, conn.socket, buf, conn, on_response_sent)
}


@(private)
on_response_sent :: proc(conn_: rawptr, sent: int, err: net.Network_Error) {
	conn := cast(^Connection)conn_

	if err != nil {
		log.errorf("could not send response: %v", err)
		if !connection_set_state(conn, .Will_Close) do return
	}

	clean_request_loop(conn)
}

// Response has been sent, clean up and close/handle next.
@(private)
clean_request_loop :: proc(conn: ^Connection, close: Maybe(bool) = nil) {
	blocks, size, used := allocator_free_all(&conn.temp_allocator)
	log.debugf("temp_allocator had %d blocks of a total size of %m of which %m was used", blocks, size, used)

	scanner_reset(&conn.scanner)

	conn.loop.req = {}
	conn.loop.res = {}

	if c, ok := close.?; (ok && c) || conn.state == .Will_Close {
		connection_close(conn)
	} else {
		if !connection_set_state(conn, .Idle) do return
		conn_handle_req(conn, context.temp_allocator)
	}
}

// A server MUST NOT send a Content-Length header field in any response
// with a status code of 1xx (Informational) or 204 (No Content).  A
// server MUST NOT send a Content-Length header field in any 2xx
// (Successful) response to a CONNECT request.
@(private)
response_needs_content_length :: proc(r: ^Response, conn: ^Connection) -> bool {
	if status_is_informational(r.status) || r.status == .No_Content {
		return false
	}

	if rline, ok := conn.loop.req.line.(Requestline); ok {
		if status_is_success(r.status) && rline.method == .Connect {
			return false
		}

		return true
	}

	return true
}

@(private)
response_can_have_body :: proc(r: ^Response, conn: ^Connection) -> bool {
	response_needs_content_length(r, conn) or_return

	if rline, ok := conn.loop.req.line.(Requestline); ok {
		return rline.method != .Head
	}

	return true
}

// Determines if the connection needs to be closed after sending the response.
@(private)
response_must_close :: proc(req: ^Request, res: ^Response) -> bool {
	// If the request we are responding to indicates it is closing the connection, close our side too.
	if req, req_has := headers_get_unsafe(req.headers, "connection"); req_has && req == "close" {
		return true
	}

	// If we are responding with a close connection header, make sure we close.
	if res, res_has := headers_get_unsafe(res.headers, "connection"); res_has && res == "close" {
		return true
	}

	// If the body was tried to be received, but failed, close.
	if body_ok, got_body := req._body_ok.?; got_body && !body_ok {
		headers_set_close(&res.headers)
		return true
	}

	// If the connection's state indicates closing, close.
	if res._conn.state >= .Will_Close {
		headers_set_close(&res.headers)
		return true
	}

	return false
}
