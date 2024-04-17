package client

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:testing"

import ssl  "../openssl"
import nbio "../nbio/poly"

@(test)
test_client :: proc(t: ^testing.T) {
    logger := log.create_console_logger()
    context.logger = logger

	io, errno := nbio.make_io(); assert(errno == 0, "io couldn't be initialized")
	defer nbio.destroy(&io)

	client := client_make(&io)
	defer destroy(&client)

	// {
	// 	req := request_make()
	// 	defer destroy(&req)
	//
	// 	// Makes a connection internally, cleaning it up afterwards.
	// 	request(client, req)
	// }

    #unroll for i in 0..<5 {
        connection := connection_make(&client, "laytanlaats.com", .HTTPS)
		defer destroy(&connection)

        connect(&connection, nil, proc(c: ^Connection, _: rawptr, err: net.Network_Error) {
            fmt.printfln("connect callback: %v", err)
            // fmt.printfln("%#v", c)
        })

		req := request_make(&connection, "/")
		defer destroy(&req)

        request(req)
        // request(req)
        // request(req)
        // request(req)
        // request(req)

		// // Uses given connection, allowing reuse/keep-alive.
		// request(connection, req)
		//
		// req.method = .Post
		// request(connection, req)
	}

	done: bool
	// context.user_ptr = &done
	//
	// r: Request
 //    err := request_init(&io, &r, "https://echoserver.dev/server")
 //    fmt.assertf(err == nil, "reqeust init error: %v", err)
	//
 //    log.debug("connection initialized, connecting to server...")
	//
 //    on_connect :: proc(r: ^Request, _: rawptr, err: net.Network_Error) {
 //        fmt.assertf(err == nil, "connect error: %v", err)
	//
 //        log.debug("connected, sending request...")
	//
 //        send(r, nil, on_sent)
 //    }
	//
 //    on_sent :: proc(r: ^Request, _: rawptr, err: net.Network_Error) {
 //        fmt.assertf(err == nil, "send error: %v", err)
	//
 //        log.debug("request sent, receiving response...")
	//
 //        parse_response(r, r, on_response)
 //    }
	//
 //    on_response :: proc(res: ^Response, r: rawptr, err: net.Network_Error) {
 //        // r := (^Request)(r)
 //        fmt.assertf(err == nil, "send error: %v", err)
	//
 //        log.debug("received first part of response, retrieving body...")
	//
 //        log.info(res.status, res.headers._kv, res.cookies)
	//
 //        ssl.errors_print_to_stderr()
	//
	// 	(^bool)(context.user_ptr)^ = true
 //    }
	//
 //    connect(&r, nil, on_connect)

	// Start the event loop.
	terrno: os.Errno
	for terrno == os.ERROR_NONE && !done {
		terrno = nbio.tick(&io)
	}
	testing.expect(t, terrno == os.ERROR_NONE, "tick error")
}
