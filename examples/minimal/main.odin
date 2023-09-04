package minimal_example

import "core:fmt"
import "core:log"

import http "../.."

// Minimal server that listens on 127.0.0.1:8080 and responds to every request with 200 Ok.
main :: proc() {
	context.logger = log.create_console_logger(.Debug)

	s: http.Server

	handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
		res.status = .OK
		http.respond(res)
	})

	http.server_shutdown_on_interrupt(&s)

	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))
}
