/*
Async handler examples for odin-http.

Async handlers let the handler return immediately and get called again with the result.

The same proc handles both calls. res.work_data == nil on the first call:

	my_handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	    if res.work_data == nil {
	        // first call: allocate work struct, mark_async, start background work, return
	    } else {
	        // second call: work is done, send response, free work struct
	        defer { res.work_data = nil }
	    }
	}

The first call runs inside nbio.tick() — return quickly, the event loop is blocked
until you do. The second call runs after tick() returns, when the server loop
calls the second parts of pending async handlers.

Allocate the work struct in the first call, store it via mark_async (saved in
res.work_data), read it in the second call, free before returning.

Examples
--------
ping_pong.odin           no thread; body callback calls mark_async + resume inline
without_body_async.odin  no body needed; spawns a thread in the first call
with_body_async.odin     reads body first; body callback spawns the thread

Note: these use thread.create per request to keep the flow easy to follow.
In production, use a worker pool. Only the completion code calls http.resume(res).

API
---
mark_async(h, res, work)
    Tells the server this request is going async.
    Call it before starting background work.

cancel_async(res)
    Call it to undo mark_async when background work fails to start.

resume(res)
    Schedules the second handler call. Call it from the background thread when work
    is done, exactly once. Don't touch res after this.

The background thread owns the work struct and may call resume once. From a
background thread:
- don't read or write res fields - res purpose just carry "async" info between calls
- don't call any http.* proc except resume
- don't allocate from context.temp_allocator (it's the per-connection arena, not thread-safe)

*/
package async_examples
