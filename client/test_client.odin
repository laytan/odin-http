package client

import "core:fmt"
import "core:log"
import "core:net"
import "core:os"
import "core:testing"

import ssl  "../openssl"
import nbio "../nbio/poly"

@(test)
test_client :: proc() {
    logger := log.create_console_logger(.Info)
    context.logger = logger

	io: nbio.IO
	nbio.init(&io)
	defer nbio.destroy(&io)

	client := client_make(&io)
	defer destroy(&client)

	REQUESTS    :: 1000
	CONNECTIONS :: 100

	done: int

	for i in 0..<CONNECTIONS {
		log.debug(i)
		connection := new(Connection)
		connection_init(connection, &client, "localhost:6969", .HTTP)

		for j in 0..<REQUESTS {
			log.debug(j)
			req := new(Request)
			request_init(req, connection, "/api")

			request(req, &done, proc(r: ^Request, done: rawptr, err: net.Network_Error) {
				log.info(r.res.status, r.res.body, err)
				(^int)(done)^ += 1
			})
		}
	}

	terrno: os.Errno
	for terrno == os.ERROR_NONE && done != REQUESTS*CONNECTIONS {
		terrno = nbio.tick(&io)
	}
	assert(terrno == 0)
}
