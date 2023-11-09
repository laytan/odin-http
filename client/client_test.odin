package client

import "core:net"
import "core:mem"
import "core:testing"
import "core:fmt"
import "core:log"
import "core:time"

import nbio "../nbio/poly"

@(test)
test_client :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger(.Debug)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	defer {
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %m\n", leak.location, leak.size)
		}
		for bad_free in track.bad_free_array {
			fmt.printf("%v allocation %p was freed badly\n", bad_free.location, bad_free.memory)
		}
	}

	{
		c: Client
		client_init(&c)
		defer client_destroy(&c)

		for nbio.num_waiting(&c.io) > 0 {
			errno := nbio.tick(&c.io)
			assert(errno == 0)
		}

		resolve(&c, "google.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
			if err != nil {
				log.warnf("error resolving google: %v", err)
				return
			}

			log.infof("www.google.com resolves to: %s", net.endpoint_to_string(ep))
		})

		resolve(&c, "google.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
			if err != nil {
				log.warnf("error resolving 2nd google: %v", err)
				return
			}

			log.infof("2nd www.google.com resolves to: %s", net.endpoint_to_string(ep))
		})

		resolve(&c, "developer.arm.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
			if err != nil {
				log.warnf("error resolving arm: %v", err)
				return
			}

			log.infof("developer.arm.com resolves to: %s", net.endpoint_to_string(ep))
		})

		nbio.timeout(&c.io, time.Second * 2, &c, proc(c: ^Client, _: Maybe(time.Time)) {
			resolve(c, "www.google.com", nil, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
				if err != nil {
					log.warnf("error resolving 3nd google: %v", err)
					return
				}

				log.infof("3nd www.google.com resolves to: %s", net.endpoint_to_string(ep))
			})
		})

		for nbio.num_waiting(&c.io) > 0 {
			errno := nbio.tick(&c.io)
			assert(errno == 0)
		}
	}
}

@(test)
test_job_args :: proc(t: ^testing.T) {
	@static tt: ^testing.T
	tt = t

	run(
		batch(
			job1(u8(5), proc(j: ^Job, m: Handle_Mode, d: u8) {
				testing.log(tt, j.user_args)
				testing.expect_value(tt, d, 5)
			}),
			job1(u128(5), proc(j: ^Job, m: Handle_Mode, d: u128) {
				testing.log(tt, j.user_args)
				testing.expect_value(tt, d, 5)
			}),
			job2(u64(5), u64(513), proc(j: ^Job, m: Handle_Mode, d: u64, d2: u64) {
				testing.log(tt, j.user_args)
				testing.expect_value(tt, d, 5)
				testing.expect_value(tt, d2, 513)
			})
		),
	)
}
