package client

import "core:log"
import "core:net"
import "core:os"
import "core:testing"

import "dns"

import nbio "../nbio/poly"

@(test)
test_client :: proc(t: ^testing.T) {
    logger := log.create_console_logger(.Debug)
    context.logger = logger

	State :: struct {
		io:     nbio.IO,
		dnsc:   dns.Client,
		client: Client,
		conn:   Connection,
		req:    Request,
	}
	state: State

	nbio.init(&state.io)
	defer nbio.destroy(&state.io)

	dns.init(&state.dnsc, &state.io, &state, proc(c: ^dns.Client, user: rawptr, name_servers_err: dns.Init_Error, hosts_err: dns.Init_Error) {
		if name_servers_err != nil || hosts_err != nil {
			panic("DNS init failure")
		}

		state := (^State)(user)

		client_init(&state.client, &state.io, &state.dnsc)
		connection_init(&state.conn, &state.client, "https://github.com")

		request_init(&state.req, &state.conn, "/laytan")
		request(&state.req, nil, proc(r: ^Request, _: rawptr, err: net.Network_Error) {
			log.info(r.res.status)
		})
	})

	tick: int
	terrno: os.Errno
	for terrno == os.ERROR_NONE {
		terrno = nbio.tick(&state.io)
		tick += 1
	}
	assert(terrno == 0)
}
