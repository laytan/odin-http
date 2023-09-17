package http

import "core:container/queue"
import "core:net"
import "core:strings"
import "core:bytes"

import "nbio"

Sse :: struct {
	user_data: rawptr,
	on_err:    Maybe(Sse_On_Error),

	r:         ^Response,
	events:    queue.Queue(Sse_Event),
	state:     Sse_State,
}

Sse_Event :: struct {
	event:   Maybe(string),
	data:    Maybe(string),
	id:      Maybe(int),
	retry:   Maybe(int),
	comment: Maybe(string),

	_buf:    strings.Builder,
	_sent:   int,
}

Sse_State :: enum {
	Uninitialized,

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
A handler that is called when there is an error or when sse_end is called.
This will always be called in a cycle, and only once.
If this is called after a sse_end call the err is nil.
This is called before the connection is closed.
*/
Sse_On_Error :: #type proc(sse: ^Sse, err: net.Network_Error)

/*
Initialize the Sse struct, and start sending the status code and headers.
*/
sse_start :: proc(sse: ^Sse, r: ^Response, user_data: rawptr = nil, on_error: Maybe(Sse_On_Error) = nil) {
	sse.r         = r
	sse.user_data = user_data
	sse.on_err    = on_error
	sse.state     = .Starting

	r.status = .OK
	r.headers["cache-control"] = "no-store"
	r.headers["content-type"]  = "text/event-stream"
	_response_write_heading(r, -1)

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

	buf := bytes.buffer_to_bytes(&r._buf)
	r._conn.loop.inflight = Response_Inflight {
		buf = buf,
	}
	nbio.send(&td.io, r._conn.socket, buf, sse, on_start_send)
}

/*
Queues an event to be sent over the connection.
You must call `sse_start` first, this is a no-op when end has been called or an error has occurred.
*/
sse_event :: proc(sse: ^Sse, ev: Sse_Event, loc := #caller_location) {
	switch sse.state {
	case .Starting, .Sending, .Ending, .Idle:
		queue.push_back(&sse.events, ev)
		_sse_event_prepare(queue.peek_back(&sse.events))

	case .Uninitialized:
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
sse_force_end :: proc(sse: ^Sse) {
	sse.state = .Close
	if cb, ok := sse.on_err.?; ok do cb(sse, nil)
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

	if cb, ok := sse.on_err.?; ok do cb(sse, nil)
	connection_close(sse.r._conn)
}

_sse_err :: proc(sse: ^Sse, err: net.Network_Error) {
	if sse.state >= .Ending do return

	sse.state = .Close

	if cb, ok := sse.on_err.?; ok do cb(sse, err)
	connection_close(sse.r._conn)
}

_sse_process :: proc(sse: ^Sse) {
	if sse.state == .Close do return

	if queue.len(sse.events) == 0 {
		#partial switch sse.state {
		// We have sent all events in the queue, complete the ending if we are.
		case .Ending: sse_force_end(sse)
		case:         sse.state = .Idle
		}
		return
	}

	ev := queue.peek_front(&sse.events)

	#partial switch sse.state {
	case .Ending: // noop
	case: sse.state = .Sending
	}

	nbio.send(&td.io, sse.r._conn.socket, ev._buf.buf[:], sse, _sse_on_send)
}

_sse_on_send :: proc(sse: rawptr, n: int, err: net.Network_Error) {
	sse := cast(^Sse)sse
	ev  := queue.peek_front(&sse.events)

	if err != nil {
		_sse_err(sse, err)
		return
	}

	if sse.state == .Close do return

	ev._sent += n
	if len(ev._buf.buf) > ev._sent {
		nbio.send(&td.io, sse.r._conn.socket, ev._buf.buf[ev._sent:], sse, _sse_on_send)
		return
	}

	queue.pop_front(&sse.events)
	_sse_process(sse)
}

// TODO :doesn't handle multiline values
_sse_event_prepare :: proc(ev: ^Sse_Event) {
	b := &ev._buf

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
		strings.write_int(b, id)
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
