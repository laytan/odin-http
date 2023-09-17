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
		sse := new(http.Sse)

		http.sse_start(sse, res, rawptr(uintptr(0)), proc(sse: ^http.Sse, err: net.Network_Error) {
			log.errorf("sse error: %v", err)
		})

		http.sse_event(sse, {data = "Hello, World!"})

		tick :: proc(sse: rawptr, now: Maybe(time.Time)) {
			sse := cast(^http.Sse)sse

			if sse.state > .Ending do return

			nbio.timeout(&http.td.io, time.Second, sse, tick)

			http.sse_event(sse, {
				id    = int(uintptr(sse.user_data)),
				event = "tick",
				data  = http.date_string(now.? or_else time.now()),
			})

			if uintptr(sse.user_data) > 10 {
				http.sse_end(sse)
			}

			sse.user_data = rawptr(uintptr(sse.user_data) + 1)
		}
		tick(sse, nil)
	})

	http.server_shutdown_on_interrupt(&s)

	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))
}
