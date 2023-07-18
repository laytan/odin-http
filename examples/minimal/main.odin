package main

import "core:net"
import "core:fmt"
import "core:log"

import http "../.."

// Minimal server that listens on 127.0.0.1:8080 and responds to every request with "Hello, Odin!".
main :: proc() {
	context.logger = log.create_console_logger()

	s: http.Server

	handler := http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "Hello, Odin!")
	})

	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))
}
