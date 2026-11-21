package async_examples

import http "../.."
import "core:mem"
import "core:thread"
import "core:time"

Body_Context :: struct {
	alloc: mem.Allocator,
}

Body_Work :: struct {
	alloc:  mem.Allocator,
	thread: ^thread.Thread,
	body:   string,
	result: string,
}

body_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	if res.work_data == nil {
		// body callback only gets user_data (res), not h
		res.async_handler = h
		http.body(req, -1, res, body_callback)
		return
	}

	work := (^Body_Work)(res.work_data)
	defer {
		thread.join(work.thread) // the thread is already done — it called resume before we got here
		thread.destroy(work.thread)
		free(work, work.alloc)
		res.work_data = nil
	}

	http.respond_plain(res, work.result)
}

// runs on the IO thread inside nbio.tick(), after the full body is received
body_callback :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	res := (^http.Response)(user_data)
	ctx := (^Body_Context)(res.async_handler.user_data)

	if err != nil {
		http.respond(res, http.body_error_status(err))
		return
	}

	work := new(Body_Work, ctx.alloc)
	work.alloc = ctx.alloc
	work.body = string(body)

	// mark_async before thread.start, same as the direct pattern
	http.mark_async(res.async_handler, res, work)

	t := thread.create(body_background_proc)
	if t == nil {
		// both required: cancel_async tells the server, respond tells the client
		http.cancel_async(res)
		free(work, ctx.alloc)
		http.respond(res, http.Status.Internal_Server_Error)
		return
	}
	t.data = res
	work.thread = t
	thread.start(t)
}

body_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Body_Work)(res.work_data)

	// context.temp_allocator is the connection's arena — not ours to use from a background thread
	old_temp := context.temp_allocator
	defer {context.temp_allocator = old_temp}

	time.sleep(10 * time.Millisecond)

	// write result before calling resume — don't touch res after that
	work.result = work.body
	http.resume(res)
}
