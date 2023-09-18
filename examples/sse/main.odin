package sse_example

import "core:fmt"
import "core:log"
import "core:time"
import "core:net"

import http "../.."
import "../../nbio"

// Minimal server that listens on 127.0.0.1:8080 and responds to every request with 200 Ok.
main :: proc() {
	context.logger = log.create_console_logger(.Debug)

	s: http.Server

	handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
		res.headers["access-control-allow-origin"] = "*"

		sse: http.Sse
		http.sse_init(&sse, res)
		http.sse_start(&sse)

		http.sse_event(&sse, {data = "Hello, World!"})

		tick :: proc(sse: rawptr, now: Maybe(time.Time) = nil) {
			sse := cast(^http.Sse)sse
			i := uintptr(sse.user_data)

			// If you were using a custom allocator:
			// the temp_allocator is automatically free'd after the response is sent and the connection is closed.
			// if sse.state == .Close do free(sse)

			if sse.state > .Ending do return

			nbio.timeout(&http.td.io, time.Second, sse, tick)

			http.sse_event(sse, {
				event = "tick",
				data  = http.date_string(now.? or_else time.now()),
			})

			// End after a minute.
			if i > uintptr(time.Second * 60) {
				http.sse_end(sse)
			}

			sse.user_data = rawptr(i + 1)
		}
		tick(&sse)
	})

	http.server_shutdown_on_interrupt(&s)

	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))
}
