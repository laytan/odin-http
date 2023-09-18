package http

import "core:bytes"
import "core:container/queue"
import "core:log"
import "core:net"
import "core:strings"

import "nbio"

// TODO: might make sense as its own package (sse).

// TODO: shutdown doesn't work.

Sse :: struct {
	user_data: rawptr,
	on_err:    Maybe(Sse_On_Error),

	r:         ^Response,

	// State should be considered read-only by users.
	state:     Sse_State,

	_events:   queue.Queue(Sse_Event),

	_buf:      strings.Builder,
	_sent:     int,
}

Sse_Event :: struct {
	event:   Maybe(string),
	data:    Maybe(string),
	id:      Maybe(string),
	retry:   Maybe(int),
	comment: Maybe(string),
}

Sse_State :: enum {
	Pre_Start,

	// The initial HTTP response is being sent over the connection (status code&headers) before
	// we can start sending events.
	Starting,

	// No events are being sent over the connection but it is ready to.
	Idle,

	// An event is being sent over the connection.
	Sending,

	// Set to when sse_end is called when there are still events in the queue.
	// The events in the queue will be processed and then closed.
	Ending,

	// Either done ending or forced ending.
	// Every callback will return immediately, nothing else is processed.
	Close,
}

/*
A handler that is called when there is an error (client disconnected for example) or when sse_end is called.
This will always be called in a cycle, and only once, so cleaning up after yourself is easily done here.
If this is called after a sse_end call the err is nil.
This is called before the connection is closed.
*/
Sse_On_Error :: #type proc(sse: ^Sse, err: net.Network_Error)

/*
Initializes an sse struct with the given arguments.
*/
sse_init :: proc(
	sse: ^Sse,
	r: ^Response,
	user_data: rawptr = nil,
	on_error: Maybe(Sse_On_Error) = nil,
	allocator := context.temp_allocator,
) {
	sse.r = r
	sse.user_data = user_data
	sse.on_err = on_error

	queue.init(&sse._events, allocator = allocator)
	strings.builder_init(&sse._buf, allocator)

	// Set the status and content type if they haven't been changed by the user.
	if r.status == .Not_Found do r.status = .OK
	if "content-type" not_in r.headers do r.headers["content-type"] = "text/event-stream"
}

/*
Start by sending the status code and headers.
*/
sse_start :: proc(sse: ^Sse) {
	sse.state = .Starting
	_response_write_heading(sse.r, -1)

	// TODO: use other response logic from response_send proc, have a way to send a response without
	// actually cleaning up the request, and a way to hook into when that is done.

	on_start_send :: proc(sse: rawptr, n: int, err: net.Network_Error) {
		sse := cast(^Sse)sse

		if err != nil {
			_sse_err(sse, err)
			return
		}

		res := &sse.r._conn.loop.inflight.(Response_Inflight)

		res.sent += n
		if len(res.buf) != res.sent {
			nbio.send(&td.io, sse.r._conn.socket, res.buf[res.sent:], sse, on_start_send)
			return
		}

		_sse_process(sse)
	}

	buf := bytes.buffer_to_bytes(&sse.r._buf)
	sse.r._conn.loop.inflight = Response_Inflight {
		buf = buf,
	}
	nbio.send(&td.io, sse.r._conn.socket, buf, sse, on_start_send)
}

/*
Queues an event to be sent over the connection.
You must call `sse_start` first, this is a no-op when end has been called or an error has occurred.
*/
sse_event :: proc(sse: ^Sse, ev: Sse_Event, loc := #caller_location) {
	switch sse.state {
	case .Starting, .Sending, .Ending, .Idle:
		queue.push_back(&sse._events, ev)

	case .Pre_Start:
		panic("sse_start must be called first", loc)

	case .Close:
	}

	if sse.state == .Idle {
		_sse_process(sse)
	}
}

/*
Ends the event stream without sending all queued events.
*/
sse_end_force :: proc(sse: ^Sse) {
	sse.state = .Close

	_sse_call_on_err(sse, nil)
	sse_destroy(sse)
	connection_close(sse.r._conn)
}

/*
Ends the event stream as soon as all queued events are sent.
*/
sse_end :: proc(sse: ^Sse) {
	if sse.state >= .Ending do return

	if sse.state == .Sending {
		sse.state = .Ending
		return
	}

	sse.state = .Close

	_sse_call_on_err(sse, nil)
	sse_destroy(sse)
	connection_close(sse.r._conn)
}

/*
Destroys any memory allocated, and if `sse_new` was used, frees the sse struct.
This is usually not a call you need to make, it is automatically called after an error or `sse_end`/`sse_end_force`.
*/
sse_destroy :: proc(sse: ^Sse) {
	strings.builder_destroy(&sse._buf)
	queue.destroy(&sse._events)
}

_sse_err :: proc(sse: ^Sse, err: net.Network_Error) {
	if sse.state >= .Ending do return

	sse.state = .Close

	_sse_call_on_err(sse, err)
	sse_destroy(sse)
	connection_close(sse.r._conn)
}

_sse_call_on_err :: proc(sse: ^Sse, err: net.Network_Error) {
	if cb, ok := sse.on_err.?; ok {
		cb(sse, err)
	} else if err != nil {
		// Most likely that the client closed the connection.
		log.infof("Server Sent Event error: %v", err)
	}
}

_sse_process :: proc(sse: ^Sse) {
	if sse.state == .Close do return

	if queue.len(sse._events) == 0 {
		#partial switch sse.state {
		// We have sent all events in the queue, complete the ending if we are.
		case .Ending:
			sse_end_force(sse)
		case:
			sse.state = .Idle
		}
		return
	}

	#partial switch sse.state {
	case .Ending: // noop
	case:
		sse.state = .Sending
	}

	_sse_event_prepare(sse)
	nbio.send(&td.io, sse.r._conn.socket, sse._buf.buf[:], sse, _sse_on_send)
}

_sse_on_send :: proc(sse: rawptr, n: int, err: net.Network_Error) {
	sse := cast(^Sse)sse

	if err != nil {
		_sse_err(sse, err)
		return
	}

	if sse.state == .Close do return

	sse._sent += n
	if len(sse._buf.buf) > sse._sent {
		nbio.send(&td.io, sse.r._conn.socket, sse._buf.buf[sse._sent:], sse, _sse_on_send)
		return
	}

	queue.pop_front(&sse._events)
	_sse_process(sse)
}

// TODO :doesn't handle multiline values
_sse_event_prepare :: proc(sse: ^Sse) {
	ev := queue.peek_front(&sse._events)
	b := &sse._buf

	strings.builder_reset(b)
	sse._sent = 0

	if name, ok := ev.event.?; ok {
		strings.write_string(b, "event: ")
		strings.write_string(b, name)
		strings.write_string(b, "\r\n")
	}

	if cmnt, ok := ev.comment.?; ok {
		strings.write_string(b, "; ")
		strings.write_string(b, cmnt)
		strings.write_string(b, "\r\n")
	}

	if id, ok := ev.id.?; ok {
		strings.write_string(b, "id: ")
		strings.write_string(b, id)
		strings.write_string(b, "\r\n")
	}

	if retry, ok := ev.retry.?; ok {
		strings.write_string(b, "retry: ")
		strings.write_int(b, retry)
		strings.write_string(b, "\r\n")
	}

	if data, ok := ev.data.?; ok {
		strings.write_string(b, "data: ")
		strings.write_string(b, data)
		strings.write_string(b, "\r\n")
	}

	strings.write_string(b, "\r\n")
}
