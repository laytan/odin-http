package client

import "core:net"
import "core:log"
import "core:testing"
import "core:fmt"

import nbio "../nbio/poly"
import bt "../../obacktracing"

@(test)
test_client :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger(.Debug)
	context.assertion_failure_proc = bt.assertion_failure_proc

	track: bt.Tracking_Allocator
	bt.tracking_allocator_init(&track, 16, context.allocator)
	bt.tracking_allocator_destroy(&track)
	defer bt.tracking_allocator_destroy(&track)
	context.allocator = bt.tracking_allocator(&track)
	defer bt.tracking_allocator_print_results(&track, .Bad_Frees)

	{
		c: Client
		client_init(&c)
		defer client_destroy(&c)

		resolve(&c, "google.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
			if err != nil {
				log.warnf("error resolving google: %v", err)
				return
			}

			log.infof("www.google.com resolves to: %s", net.endpoint_to_string(ep))
		})

		// resolve(&c, "google.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
		// 	if err != nil {
		// 		log.warnf("error resolving 2nd google: %v", err)
		// 		return
		// 	}
		//
		// 	log.infof("2nd www.google.com resolves to: %s", net.endpoint_to_string(ep))
		// })
		//
		// resolve(&c, "developer.arm.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
		// 	if err != nil {
		// 		log.warnf("error resolving arm: %v", err)
		// 		return
		// 	}
		//
		// 	log.infof("developer.arm.com resolves to: %s", net.endpoint_to_string(ep))
		// })
		//
		// nbio.timeout(&c.io, time.Second * 2, &c, proc(c: ^Client, _: Maybe(time.Time)) {
		// 	resolve(c, "www.google.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
		// 		if err != nil {
		// 			log.warnf("error resolving 3nd google: %v", err)
		// 			return
		// 		}
		//
		// 		log.infof("3nd www.google.com resolves to: %s", net.endpoint_to_string(ep))
		// 	})
		// })

		for nbio.num_waiting(&c.io) > 0 {
			errno := nbio.tick(&c.io)
			assert(errno == 0)
		}

		fmt.println(c.dns["google.com"])
	}
}
