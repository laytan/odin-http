package tests_client

import "core:fmt"
import "core:log"
import "core:net"
import "core:sync"
import "core:testing"

import http ".."

ev :: testing.expect_value

require_value :: proc(t: ^testing.T, val: $T, test: T, format := "", args: ..any, loc := #caller_location) {
	if !testing.expect_value(t, val, test, loc) {
		testing.fail_now(t, fmt.tprintf(format, ..args), loc)
	}
}

rv :: require_value

get_endpoint :: proc() -> net.Endpoint {
	@static mu: sync.Mutex
	sync.guard(&mu)

	PORT_START :: 4000
	@static port: int
	if port == 0 {
		port = PORT_START
	}

	port += 1
	return {net.IP4_Loopback, port}
}

@(test)
test_ok :: proc(tt: ^testing.T) {
	@static s: http.Server
	@static t: ^testing.T
	t = tt

	opts := http.Default_Server_Opts
	opts.thread_count = 0

	ep := get_endpoint()


	rv(t, http.listen(&s, ep, opts), nil)

	///

	client: http.Client
	http.client_init(&client, http.io())

	req := http.Client_Request{
		url = http.url_parse(net.endpoint_to_string(ep)), // TODO: just make this a string.
	}

	http.client_request(&client, req, &client, proc(res: http.Client_Response, user: rawptr, err: http.Request_Error) {
		client := (^http.Client)(user)

		ev(t, err, nil)
		ev(t, res.status, http.Status.OK)
		ev(t, http.headers_has_unsafe(res.headers, "date"), true)
		ev(t, http.headers_has_unsafe(res.headers, "content-length"), true)
		ev(t, len(res.body), 0)

		log.info("cleaning up")

		http.response_destroy(client, res)
		http.client_destroy(client)
		http.server_shutdown(&s) // NOTE: this takes a bit because of the close delay.
	})

	///

	handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
		res.status = .OK
		http.respond(res)
	})
	ev(t, http.serve(&s, handler), nil)
}
