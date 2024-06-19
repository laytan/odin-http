package tests_client

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"

import http ".."
import      "../nbio"

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
		url = net.endpoint_to_string(ep),
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

@(test)
connection_pool :: proc(t: ^testing.T) {
	s: http.Server
	ep := get_endpoint()

	server_thread := thread.create_and_start_with_poly_data3(t, &s, &ep, proc(t: ^testing.T, s: ^http.Server, ep: ^net.Endpoint) {
		opts := http.Default_Server_Opts
		opts.thread_count = 0

		handler := http.handler(proc(_: ^http.Request, res: ^http.Response) {
			res.status = .OK
			http.respond(res)
		})

		ev(t, http.listen_and_serve(s, handler, ep^, opts), nil)
	}, init_context=context)
	defer thread.destroy(server_thread)

	io: nbio.IO
	ev(t, nbio.init(&io), os.ERROR_NONE)
	defer nbio.destroy(&io)

	@static client: http.Client
	http.client_init(&client, &io)

	req := http.Client_Request{
		url = net.endpoint_to_string(ep),
	}

	for _ in 0..<2 {
		http.client_request(&client, req, t, on_response)
		http.client_request(&client, req, t, on_response)

		on_response :: proc(res: http.Client_Response, t: rawptr, err: http.Request_Error) {
			t := (^testing.T)(t)
			ev(t, err, nil)
			ev(t, res.status, http.Status.OK)
			ev(t, http.headers_has_unsafe(res.headers, "date"), true)
			ev(t, http.headers_has_unsafe(res.headers, "content-length"), true)
			ev(t, len(res.body), 0)

			http.response_destroy(&client, res)
		}

		ev(t, nbio.run(&io), os.ERROR_NONE)

		ev(t, len(client.conns), 1)
		for _, conns in client.conns {
			ev(t, len(conns), 2)
		}
	}

	http.client_destroy(&client)
	ev(t, nbio.run(&io), os.ERROR_NONE)

	http.server_shutdown(&s)
}
