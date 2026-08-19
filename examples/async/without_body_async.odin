package async_examples

import http "../.."
import "core:mem"
import "core:thread"
import "core:time"

Without_Body_Context :: struct {
	alloc: mem.Allocator,
}

Without_Body_Work :: struct {
	alloc:  mem.Allocator,
	thread: ^thread.Thread,
	result: string,
}

without_body_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	ctx := (^Without_Body_Context)(h.user_data)

	if res.work_data == nil {
		work := new(Without_Body_Work, ctx.alloc)
		work.alloc = ctx.alloc

		// mark_async before thread.start — resume must not schedule the second call before mark_async runs
		http.mark_async(h, res, work)

		t := thread.create(without_body_background_proc)
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
		return
	}

	work := (^Without_Body_Work)(res.work_data)
	defer {
		thread.join(work.thread) // the thread is already done — it called resume before we got here
		thread.destroy(work.thread)
		free(work, work.alloc)
		res.work_data = nil
	}

	http.respond_plain(res, work.result)
}

without_body_background_proc :: proc(t: ^thread.Thread) {
	res := (^http.Response)(t.data)
	work := (^Without_Body_Work)(res.work_data)

	// context.temp_allocator is the connection's arena — not ours to use from a background thread
	old_temp := context.temp_allocator
	defer {context.temp_allocator = old_temp}

	time.sleep(10 * time.Millisecond)

	// write result before calling resume — don't touch res after that
	work.result = "hello from background"
	http.resume(res)
}
