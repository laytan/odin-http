package async_examples

import http "../.."

// No background thread. Body callback calls mark_async + resume directly on the IO thread,
// inside nbio.tick(). The second handler call happens after tick() returns.

Ping_Pong_Work :: struct {
	body: string,
}

ping_pong_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.work_data == nil {
		// body callback only gets user_data (res), not h
		res.async_handler = h
		http.body(req, -1, res, ping_pong_callback)
		return
	}

	work := (^Ping_Pong_Work)(res.work_data)
	defer {res.work_data = nil}

	if work.body == "ping" {
		http.respond_plain(res, "pong")
	} else {
		http.respond(res, http.Status.Unprocessable_Content)
	}
}

// runs on the IO thread inside nbio.tick(); temp_allocator is already the connection arena
ping_pong_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	work := new(Ping_Pong_Work, context.temp_allocator)
	work.body = string(body)

	// mark_async before resume — same rule as the threaded patterns
	http.mark_async(res.async_handler, res, work)

	// schedules the second handler call — it runs after tick() returns
	http.resume(res)
}
