package client

import "core:log"
import "core:net"
import "core:os"
import "core:testing"
import "core:time"

import "dns"

import nbio "../nbio/poly"

@(test)
test_client :: proc(t: ^testing.T) {
    logger := log.create_console_logger(.Debug)
    context.logger = logger

	io: nbio.IO
	nbio.init(&io)
	defer nbio.destroy(&io)

	client: dns.Client
	client.io = &io
	client.config = net.dns_configuration // TODO: make default if not set.
	dns.init(&client)

	nbio.timeout(client.io, time.Second, &client, proc(client: ^dns.Client, _: Maybe(time.Time)) {
		log.info("Resolving")

		dns.resolve(client, "github.com", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("github.com", recs, err)
		})
		dns.resolve(client, "laytanlaats.com", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("laytanlaats.com", recs, err)
		})
		dns.resolve(client, "laytan.dev", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("laytan.dev", recs, err)
		})
		dns.resolve(client, "laytan.dev", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("laytan.dev", recs, err)
		})
		dns.resolve(client, "odin-http.laytan.dev", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("odin-http.laytan.dev", recs, err)
		})
		dns.resolve(client, "odin-http.laytan.dev", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("odin-http.laytan.dev", recs, err)
		})
		dns.resolve(client, "github.com", nil, proc(_: rawptr, recs: dns.Record, err: net.Network_Error) {
			log.info("github.com", recs, err)
		})
	})

	// log.info(net.resolve("github.com"))
	// log.info(net.resolve("laytanlaats.com"))
	// log.info(net.resolve("laytan.dev"))
	// log.info(net.resolve("laytan.dev"))
	// log.info(net.resolve("odin-http.laytan.dev"))
	// log.info(net.resolve("odin-http.laytan.dev"))
	// log.info(net.resolve("github.com"))

	// client := client_make(&io)
	// defer destroy(&client)
	//
	// REQUESTS    :: 1000
	// CONNECTIONS :: 100
	//
	// done: int
	//
	// for i in 0..<CONNECTIONS {
	// 	log.debug(i)
	// 	connection := new(Connection)
	// 	connection_init(connection, &client, "localhost:6969", .HTTP)
	//
	// 	for j in 0..<REQUESTS {
	// 		log.debug(j)
	// 		req := new(Request)
	// 		request_init(req, connection, "/api")
	//
	// 		// err := request_sync(req)
	// 		// log.info(req.res.status, req.res.body, err)
	// 		// done += 1
	//
	// 		request(req, &done, proc(r: ^Request, done: rawptr, err: net.Network_Error) {
	// 			log.info(r.res.status, r.res.body, err)
	// 			(^int)(done)^ += 1
	// 		})
	// 	}
	// }
	tick: int
	terrno: os.Errno
	for terrno == os.ERROR_NONE {
		terrno = nbio.tick(&io)
		tick += 1
		// if tick % 100000000 == 0 {
		// 	log.info(io)
		// }
	}
	assert(terrno == 0)
}
