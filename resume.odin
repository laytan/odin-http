package http

import "base:intrinsics"
import "core:log"
import nbio "core:nbio"
import mpsc "internal/mpsc"

// Tells the server this request is going async.
// Call from your handler or body callback on the IO thread, before starting background work.
// Pass h — the second call needs the right handler pointer, especially in a middleware chain
// work_data is available in the second call via res.work_data; use 1 if you don't need it.
mark_async :: proc(h: ^Handler, res: ^Response, work_data: rawptr = rawptr(uintptr(1))) {
	if res == nil || res._conn == nil || res._conn.owning_thread == nil {
		log.error("mark_async: invalid response or connection state")
		return
	}

	if atomic_load(&res._conn.server.closing) {
		log.warn("mark_async: server is closing, ignoring")
		return
	}

	if h != nil {
		res.async_handler = h
	} else if res.async_handler == nil {
		// h must be set for the second call to reach the right handler
		assert(false, "mark_async: h is nil and res.async_handler not set. Always pass h in middleware.")
		res.async_handler = &res._conn.server.handler // fallback
	}

	res.work_data = work_data
	intrinsics.atomic_add(&res._conn.owning_thread.async_pending, 1)
	log.debugf("mark_async: pending count is %d", intrinsics.atomic_load(&res._conn.owning_thread.async_pending))
}

// Undoes mark_async when background work fails to start.
cancel_async :: proc(res: ^Response) {
	if res == nil || res._conn == nil || res._conn.owning_thread == nil {
		log.error("cancel_async: invalid response or connection state")
		return
	}

	if res.work_data == nil {
		log.error("cancel_async: response is not async, nothing to undo")
		return
	}

	intrinsics.atomic_add(&res._conn.owning_thread.async_pending, -1)
	log.debugf("cancel_async: pending count is %d", intrinsics.atomic_load(&res._conn.owning_thread.async_pending))
	res.work_data = nil
	res.async_handler = nil
}

// Schedules the second handler call. Call from the background thread when work is done.
// Don't touch res after this.
resume :: proc(res: ^Response) {
	if res == nil || res._conn == nil || res._conn.owning_thread == nil {
		log.error("resume: invalid response or connection state")
		return
	}

	td := res._conn.owning_thread
	event_loop := td.event_loop
	msg: Maybe(^Response) = res
	if mpsc.push(&td.resume_queue, &msg) {
		nbio.wake_up(event_loop)
	}
}
