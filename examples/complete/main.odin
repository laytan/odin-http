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

	// Set up routing
	router: http.Router
	http.router_init(&router)
	defer http.router_destroy(&router)

	// Routes are tried in order.
    // Route matching is implemented using an implementation of Lua patterns, see the docs on them here:
    // https://www.lua.org/pil/20.2.html
    // They are very similar to regex patterns but a bit more limited, which makes them much easier to implement since Odin does not have a regex implementation.

	// Matches /users followed by any word (alphanumeric) followed by /comments and then / with any number.
	// The word is available as params[0], and the number as params[1].
	http.route_get(&router, "/users/(%w+)/comments/(%d+)", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, fmt.tprintf("user %s, comment: %s", req.url_params[0], req.url_params[1]))
	}))

	// You can apply a rate limit just like any other middleware,
	// this one only applies to the /cookies route, but moving it higher up would match others too:
	cookies := http.handler(cookies)
	limit_msg := "Only one cookie is allowed per second, slow down!"
	limited_cookies := http.middleware_rate_limit(&cookies, &http.Rate_Limit_Opts{
		window   = time.Second,
		max      = 1,
		on_limit = http.on_limit_message(&limit_msg),
	})
	http.route_get(&router,  "/cookies", limited_cookies)

	http.route_get(&router,  "/api",     http.handler(api))
	http.route_get(&router,  "/ping",    http.handler(ping))

	// Can also have specific middleware for each route:
	index_handler := http.handler(index)
	index_with_middleware := http.middleware_proc(&index_handler, proc(handler: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		// Before calling the actual handler, can check the request and decide to pass to handler or not, or set a header for example.
		log.info("about to call the index handler")

		// Pass the request to the next handler.
		next := handler.next.(^http.Handler)
		next.handle(next, req, res)

		// The next handler has finished, we can now do things with the response.
		log.infof("index handler returned status code: %s", res.status)
	})
	http.route_get(&router,  "/", index_with_middleware)

	// Matches every get request that did not match another route.
	http.route_get(&router,  "(.*)", http.handler(static))

	http.route_post(&router, "/ping", http.handler(post_ping))

	route_handler := http.router_handler(&router)

	// Wrap our handler with a logger middleware.
	with_logger := http.middleware_logger(&route_handler, &http.Logger_Opts{log_time = true})

	// Start the server on 127.0.0.1:6969.
	err := http.listen_and_serve(
		&s,
		&with_logger,
		net.Endpoint{address = net.IP4_Loopback, port = 6969},
	)
	log.warnf("server stopped: %s", err)
}

cookies :: proc(req: ^http.Request, res: ^http.Response) {
	append(
		&res.cookies,
		http.Cookie{
			name = "Session",
			value = "123",
			expires_gmt = time.now(),
			max_age_secs = 10,
			http_only = true,
			same_site = http.Same_Site.Lax,
		},
	)
	http.respond_plain(res, "Yo!")
}

api :: proc(req: ^http.Request, res: ^http.Response) {
	if err := http.respond_json(res, req.line, req.allocator); err != nil {
		log.errorf("could not respond with JSON: %s", err)
	}
}

ping :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_plain(res, "pong")
}

index :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_file(res, "examples/complete/static/index.html", req.allocator)
}

static :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_dir(res, "/", "examples/complete/static", req.url_params[0], req.allocator)
}

post_ping :: proc(req: ^http.Request, res: ^http.Response) {
	body, err := http.request_body(req, len("ping"))
	if err != nil {
		res.status = http.body_error_status(err)
		return
	}

	if (body.(http.Body_Plain) or_else "") != "ping" {
		res.status = .Unprocessable_Content
		return
	}

	http.respond_plain(res, "pong")
}
