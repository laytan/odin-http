package main

import "core:net"
import "core:log"
import "core:time"
import "core:fmt"
import "core:mem"
import "core:thread"
import "core:c/libc"
import "core:runtime"

import http ".."

LoggerOpts :: log.Options{.Level, .Time, .Short_File_Path, .Line, .Terminal_Color}

TRACK_LEAKS :: true

main :: proc() {
	context.logger = log.create_console_logger(log.Level.Debug, LoggerOpts)

	when TRACK_LEAKS {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
	}

	serve()

	when TRACK_LEAKS {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
		}
		for bad_free in track.bad_free_array {
			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
		}
	}
}

// In order to shutdown the server on a signal, the signal handler needs
// access to these variables.
s:  http.Server
dc: runtime.Context

serve :: proc() {
	if err := http.server_listen(&s, net.Endpoint{address = net.IP4_Any, port = 6969});
	   err != nil {
		log.errorf("could not start server: %s", err)
		return
	}
	log.infof("Listening on :6969")

	dc = context
	libc.signal(libc.SIGINT, proc "cdecl" (_: i32) {
		context = dc
		http.server_shutdown_gracefully(&s)
	})

	err := http.server_serve(&s, handle)
	log.warnf("server stopped: %s", err)
}

handle :: proc(req: ^http.Request, res: ^http.Response) {
    start := time.tick_now()
    defer {
        dur := time.tick_since(start)
        durqs := time.duration_microseconds(dur)
        if res.status < http.Status.Bad_Request {
            log.infof(
                "[%i|%.1fqs] %s %s",
                res.status,
                durqs,
                http.method_string(req.line.method),
                req.line.target,
            )
        } else {
            log.warnf(
                "[%i|%.1fqs] %s %s",
                res.status,
                durqs,
                http.method_string(req.line.method),
                req.line.target,
            )
        }
    }

    #partial switch req.line.method {
    case .Get:
        switch req.line.target {
        case "/cookies":
            append(&res.cookies, http.Cookie{
				name         = "Session",
                value        = "123",
                expires_gmt  = time.now(),
                max_age_secs = 10,
                http_only    = true,
                same_site    = http.Same_Site.Lax,
            })
            http.respond_plain(res, "Yo!")
        case "/api":
            if err := http.respond_json(res, req.line); err != nil {
                log.errorf("could not respond with JSON: %s", err)
            }
		case "/ping": http.respond_plain(res, "pong")
		case "/":     http.respond_file(res, "example/static/index.html")
		case:         http.respond_dir(res, "/", "example/static", req.line.target)
        }
    case .Post:
        switch req.line.target {
        case "/ping":
            body, err := http.request_body(req, len("ping"))
            if err != nil {
                res.status = http.body_error_status(err)
                return
            }

            if body != "ping" {
                res.status = .Unprocessable_Content
                return
            }

            http.respond_plain(res, "pong")
        }
    }
}
