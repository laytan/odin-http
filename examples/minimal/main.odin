package main

import "core:net"
import "core:fmt"
import "core:log"
import "core:mem"

import http "../.."

// Minimal server that listens on 127.0.0.1:8080 and responds to every request with "Hello, Odin!".
main :: proc() {
	context.logger = log.create_console_logger()

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	s: http.Server

	handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
		res.status = .Ok
		http.respond(res)
	})

	http.server_shutdown_on_interrupt(&s)

	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))

	for _, leak in track.allocation_map {
		fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
	}

	for bad_free in track.bad_free_array {
		fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
	}
}
