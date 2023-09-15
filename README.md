# Odin HTTP

A HTTP/1.1 implementation for Odin purely written in Odin (besides SSL).

See below examples or the examples directory.

## Compatibility

This is beta software, confirmed to work in my own use cases but can certainly contain edge cases and bugs that I did not catch.
Please file issues for any bug or suggestion you encounter/have.

Because this is still heavily in development, I do not hesitate to push API changes at the moment, so beware.

The has been tested to work with Ubuntu Linux (other "normal" distros should work), MacOS (m1 and intel), and Windows 64 bit.
Any other distributions or versions have not been tested and might not work.

## Dependencies

`odin-http` depends on OpenSSL for making HTTPS requests in the client package.
This repository contains a copy of these libraries for ease of use on Windows and Darwin.

For Linux, most distros come with OpenSSL, if not you can install it by using something like this:
- `sudo apt-get install openssl libssl-dev`
- `apk add openssl openssl-libs-static`

## Performance

Some small benchmarks have been done in the comparisons directory.

Best performance is currently on Linux because it is the only multithreaded platform, still, the other platforms
are faster than a lot of other single-threaded implementations.
Once I know the API is good on Linux and how I want the multithreading to work I will add it to the other platforms.

## IO implementations

Although these implementation details are not exposed when using the package, these are the underlying kernel API's that are used.

- Windows: [IOCP (IO Completion Ports)](https://en.wikipedia.org/wiki/Input/output_completion_port)
- Linux:   [io_uring](https://en.wikipedia.org/wiki/Io_uring)
- Darwin:  [KQueue](https://en.wikipedia.org/wiki/Kqueue)

The IO part of this package can be used on its own for other types of applications, see the nbio directory for the documentation on that.
It has APIs for reading, writing, opening, closing, seeking files and accepting, connecting, sending, receiving and closing sockets, both UDP and TCP, fully cross-platform.

## Server example

```odin
package main

import "core:fmt"
import "core:log"
import "core:net"
import "core:time"

import http "../.." // Change to path of package.

main :: proc() {
	context.logger = log.create_console_logger(.Info)

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
	// The word is available as req.url_params[0], and the number as req.url_params[1].
	http.route_get(&router, "/users/(%w+)/comments/(%d+)", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, fmt.tprintf("user %s, comment: %s", req.url_params[0], req.url_params[1]))
	}))
	http.route_get(&router, "/cookies", http.handler(cookies))
	http.route_get(&router, "/api", http.handler(api))
	http.route_get(&router, "/ping", http.handler(ping))
	http.route_get(&router, "/index", http.handler(index))

	// Matches every get request that did not match another route.
	http.route_get(&router, "(.*)", http.handler(static))

	http.route_post(&router, "/ping", http.handler(post_ping))

	routed := http.router_handler(&router)

	log.info("Listening on http://localhost:6969")

	err := http.listen_and_serve(&s, routed, net.Endpoint{address = net.IP4_Loopback, port = 6969})
	fmt.assertf(err == nil, "server stopped with error: %v", err)
}

cookies :: proc(req: ^http.Request, res: ^http.Response) {
	append(
		&res.cookies,
		http.Cookie{
			name         = "Session",
			value        = "123",
			expires_gmt  = time.now(),
			max_age_secs = 10,
			http_only    = true,
			same_site    = .Lax,
		},
	)
	http.respond_plain(res, "Yo!")
}

api :: proc(req: ^http.Request, res: ^http.Response) {
	if err := http.respond_json(res, req.line); err != nil {
		log.errorf("could not respond with JSON: %s", err)
	}
}

ping :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_plain(res, "pong")
}

index :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_file(res, "examples/complete/static/index.html")
}

static :: proc(req: ^http.Request, res: ^http.Response) {
	http.respond_dir(res, "/", "examples/complete/static", req.url_params[0])
}

post_ping :: proc(req: ^http.Request, res: ^http.Response) {
	http.body(req, len("ping"), res, proc(res: rawptr, body: http.Body, err: http.Body_Error) {
		res := cast(^http.Response)res

		if err != nil {
			http.respond(res, http.body_error_status(err))
			return
		}

		if body != "ping" {
			http.respond(res, http.Status.Unprocessable_Content)
			return
		}

		http.respond_plain(res, "pong")
	})
}
```

## Client example

```odin
package main

import "core:fmt"

import "../../client"

main :: proc() {
	get()
	post()
}

// basic get request.
get :: proc() {
	res, err := client.get("https://www.google.com/")
	if err != nil {
		fmt.printf("Request failed: %s", err)
		return
	}
	defer client.response_destroy(&res)

	fmt.printf("Status: %s\n", res.status)
	fmt.printf("Headers: %v\n", res.headers)
	fmt.printf("Cookies: %v\n", res.cookies)
	body, allocation, berr := client.response_body(&res)
	if berr != nil {
		fmt.printf("Error retrieving response body: %s", berr)
		return
	}
	defer client.body_destroy(body, allocation)

	fmt.println(body)
}

Post_Body :: struct {
	name:    string,
	message: string,
}

// POST request with JSON.
post :: proc() {
	req: client.Request
	client.request_init(&req, .Post)
	defer client.request_destroy(&req)

	pbody := Post_Body{"Laytan", "Hello, World!"}
	if err := client.with_json(&req, pbody); err != nil {
		fmt.printf("JSON error: %s", err)
		return
	}

	res, err := client.request("https://webhook.site/YOUR-ID-HERE", &req)
	if err != nil {
		fmt.printf("Request failed: %s", err)
		return
	}
	defer client.response_destroy(&res)

	fmt.printf("Status: %s\n", res.status)
	fmt.printf("Headers: %v\n", res.headers)
	fmt.printf("Cookies: %v\n", res.cookies)

	body, allocation, berr := client.response_body(&res)
	if berr != nil {
		fmt.printf("Error retrieving response body: %s", berr)
		return
	}
	defer client.body_destroy(body, allocation)

	fmt.println(body)
}
```
