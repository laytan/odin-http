package main

import "core:net"
import "core:log"
import "core:time"
import "core:fmt"
import "core:mem"

import http "../.."

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

serve :: proc() {
	s: http.Server
	// Register a graceful shutdown when the program receives a SIGINT signal.
	http.server_shutdown_on_interrupt(&s)

	// Wrap our handle proc into a Handler.
	handler     := http.handler_proc(handle)

	// Wrap our handler with a logger middleware.
	with_logger := http.middleware_logger(&handler, &http.Logger_Opts{ log_time = true })

	// Start the server on 127.0.0.1:6969.
	err := http.listen_and_serve(&s, &with_logger, net.Endpoint{address = net.IP4_Loopback, port = 6969})
	log.warnf("server stopped: %s", err)
}

handle :: proc(req: ^http.Request, res: ^http.Response) {
	rline := req.line.(http.Requestline)
    #partial switch rline.method {
    case .Get:
        switch rline.target {
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
		case "/":     http.respond_file(res, "examples/complete/static/index.html")
		case:         http.respond_dir(res, "/", "examples/complete/static", rline.target)
        }
    case .Post:
        switch rline.target {
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
