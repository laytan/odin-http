package client

import "core:net"
import "core:os"
import "core:strings"
import "core:mem"
import "core:log"
import "core:time"
import "core:fmt"

import nbio "../nbio/poly"
import job "../job"


DNS :: union {
	// ^DNS_Req,       // Inflight dns resolve.
	^job.Job,
	net.Network_Error, // Dns could not be resolved.
	net.Address,       // Resolved endpoint.
}

DNS_Req :: struct {
	// TODO: decouple DNS_Req from client so users can make dns reqs without a client.
	client:       ^Client,

	packet_buf:   [(size_of(u16be) * 6) + net.NAME_MAX + (size_of(u16be) * 2)]byte,
	response_buf: [512]byte,

	sock:         net.UDP_Socket,

	target:       net.Host,

	type:         net.DNS_Record_Type,

	result:       struct{
		records: []net.DNS_Record,
		err:     net.Network_Error,
	},

	name_server_id: int,
}

DNS_Req_Queue_Entry :: struct {
	user:   rawptr,
	target: net.Host,
	cb:     On_Resolve,
}

// TODO: keep connections open (configurable).

// TODO: timeouts.

// TODO: invalidate cache based on time to live on dns record.

Client :: struct {
	io: nbio.IO,

	// DNS specific fields.
	using _dns: struct {
		dns:               map[string]DNS,

		config_job:        ^job.Job,

		hosts_file_path:   string,
		hosts_fd:          os.Handle,
		hosts:             []net.DNS_Host_Entry,

		resolv_file_path:  string,
		resolv_fd:         os.Handle,
		name_servers:      []net.Endpoint,
	},
}

LOAD_CONFIG_TIMEOUT  :: time.Second
DNS_RESPONSE_TIMEOUT :: time.Millisecond * 250

client_init :: proc(c: ^Client) {
	c.resolv_file_path = net.dns_configuration.resolv_conf
	c.hosts_file_path  = net.dns_configuration.hosts_file

	assert(nbio.init(&c.io) == os.ERROR_NONE)

	c.config_job = job.batch(
		job.new1(c, load_hosts_job, "load hosts"),
		job.new1(c, load_resolv_conv_job, "load resolv"),
		job.new2(c, LOAD_CONFIG_TIMEOUT, timeout_job, "load config timeout"),
	)
	defer {
		job.destroy(c.config_job, .Down)
		c.config_job = nil
	}

	job.run(c.config_job)

	fmt.println("config job")
	fmt.println(c.config_job)
	fmt.println()

	// Everything we do with the client requires the config to be loaded, so it seems ok to block
	// here.
	for nbio.num_waiting(&c.io) > 0 {
		errno := nbio.tick(&c.io)
		assert(errno == 0)
	}
}

timeout_job :: proc(j: ^job.Job, m: job.Handle_Mode, c: ^Client, dur: time.Duration) {
	switch m {
	case .Cancel:
		job.done(j)
		// PERF: timeout will still run in nbio, can we remove it somehow?

	case .Run:
		nbio.timeout(&c.io, dur, j, proc(j: ^job.Job, _: Maybe(time.Time)) {
			if j.cancelled do return
			job.done(j)
			job.cancel_others_in_batch(j)
		})
	}
}

client_destroy :: proc(c: ^Client) {
	nbio.destroy(&c.io)

	delete(c.name_servers)

	for h in c.hosts do delete(h.name)
	delete(c.hosts)

	delete(c.dns)
}

On_Resolve :: #type proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error)

resolve :: proc(c: ^Client, hostname_and_maybe_port: string, user: rawptr, callback: On_Resolve) {
	target, err := net.parse_hostname_or_endpoint(hostname_and_maybe_port)
	if err != nil {
		callback(c, user, {}, err)
		return
	}

	switch t in target {
	case net.Endpoint:
		callback(c, user, t, nil)
		return

	case net.Host:
		if dns, ok := c.dns[t.hostname]; ok {
			switch d in dns {
			case net.Network_Error:
				log.infof("already got result for %s: %v", t.hostname, d)
				callback(c, user, {}, d)
				return
			case net.Address:
				log.infof("already got result for %s: %v", t.hostname, d)
				callback(c, user, net.Endpoint{d, t.port}, nil)
				return
			case ^job.Job:
				log.infof("already resolving %s, queuing", t.hostname)
				job.chain(
					d,
					job.new2(c, DNS_Req_Queue_Entry{cb = callback, user = user, target = t}, callback_job, "queued callback"),
				)
			}
			return
		}

		req := new(DNS_Req)
		req.target = t
		req.client = c

		resolve_job, err := make_resolve_job(req)
		if err != nil {
			c.dns[t.hostname] = err
			callback(c, user, {}, err)
			return
		}

		c.dns[t.hostname] = job.chain(
			resolve_job,
			job.new2(req, callback, proc(j: ^job.Job, m: job.Handle_Mode, req: ^DNS_Req, callback: On_Resolve) {
				res := req.result
				c   := req.client

				defer {
					net.destroy_dns_records(res.records)
					free(req)
					job.done(j)
				}

				if res.err == nil && len(res.records) == 0 {
					res.err = net.Resolve_Error.Unable_To_Resolve
				}

				if res.err != nil {
					c.dns[req.target.hostname] = res.err
					return
				}

				root_job := c.dns[req.target.hostname].(^job.Job)

				// Chain a cleanup job to the end, assuming that between now and all the callback jobs
				// having ran no new jobs will be chained.
				job.chain(root_job, job.new1(root_job, proc(j: ^job.Job, mode: job.Handle_Mode, root_job: ^job.Job) {
					log.debug("cleanup")
					switch mode {
					case .Cancel: unreachable()
					case .Run:    job.destroy(root_job, .Down)
					}
				}, "cleanup"))

				// NOTE: only saving the first result now, might want to do more later.

				address: net.Address = res.records[0].(net.DNS_Record_IP4).address
				c.dns[req.target.hostname] = address
			}, "resolve done"),
			job.new2(c, DNS_Req_Queue_Entry{cb = callback, user = user, target = t}, callback_job, "first callback"),
		)
		job.run(c.dns[t.hostname].(^job.Job))
		fmt.println(c.dns[t.hostname])
	}
}

callback_job :: proc(j: ^job.Job, _: job.Handle_Mode, c: ^Client, e: DNS_Req_Queue_Entry) {
	defer job.done(j)

	_res := c.dns[e.target.hostname]

	err: net.Network_Error
	ep:  net.Endpoint
	switch res in _res {
	case net.Network_Error:
		err = res
	case net.Address:
		ep.address = res
		ep.port    = e.target.port
	case ^job.Job:
		unreachable()
	case:
		unreachable()
	}

	e.cb(c, e.user, ep, err)
}

On_DNS_Records :: #type proc(c: ^Client, user: rawptr, records: []net.DNS_Record, err: net.Network_Error)

make_resolve_job :: proc(req: ^DNS_Req) -> (^job.Job, net.Network_Error) {
	if !net.validate_hostname(req.target.hostname) {
		return nil, net.DNS_Error.Invalid_Hostname_Error
	}

	c := req.client

	if len(c.name_servers) <= 0 {
		return nil, net.DNS_Error.Invalid_Resolv_Config_Error
	}

	// TODO: check host overrides.
	// {
	// 	host_overrides: [dynamic]net.DNS_Record
	// 	for host in c.hosts {
	// 		if strings.compare(host.name, hostname) != 0 {
	// 			continue
	// 		}
	//
	// 		#partial switch net.family_from_address(host.addr) {
	// 		case .IP4:
	// 			record := net.DNS_Record_IP4{
	// 				base = {
	// 					record_name = hostname,
	// 					ttl_seconds = 0,
	// 				},
	// 				address = host.addr.(net.IP4_Address),
	// 			}
	// 			append(&host_overrides, record)
	// 		case .IP6:
	// 			record := net.DNS_Record_IP6{
	// 				base = {
	// 					record_name = hostname,
	// 					ttl_seconds = 0,
	// 				},
	// 				address = host.addr.(net.IP6_Address),
	// 			}
	// 			append(&host_overrides, record)
	//
	// 		}
	// 	}
	//
	// 	if len(host_overrides) > 0 {
	// 		callback(c, user, host_overrides[:], nil)
	// 		return
	// 	}
	// }

	// TODO: send ip6 reqs too.


	root_ns := job.batch(
		job.new1(req, get_dns_records_from_nameserver_job, "get dns from ns"),
		job.new2(c, DNS_RESPONSE_TIMEOUT, timeout_job, "get dns from ns timeout"),
		batch_name="nameserver 1",
	)

	// for ns in c.name_servers[1:] {
	// 	job.chain(
	// 		root_ns,
	// 		job.batch(
	// 			job.new2(req, ns, get_dns_records_from_nameserver_job, "get dns from ns"),
	// 			job.new2(c, DNS_RESPONSE_TIMEOUT, timeout_job, "get dns from ns timeout"),
	// 			batch_name="next nameserver",
	// 		),
	// 	)
	// }

	return root_ns, nil
}

get_dns_records_from_nameserver_job :: proc(j: ^job.Job, m: job.Handle_Mode, req: ^DNS_Req) {
	name_server := req.client.name_servers[req.name_server_id]

	switch m {
	case .Cancel:
		log.info("get_dns_records_from_nameserver_job cancelled")

		defer nbio.close(&req.client.io, req.sock)

		req.name_server_id += 1

		// No more name servers left to check.
		if req.name_server_id >= len(req.client.name_servers) {
			job.done(j)
			return
		}

		// Cancel the timeout.
		job.cancel(j.batch)

		// Manually put this new job down to run the next name server, this is very clunky though.

		assert(j.parent.parent == nil, "only works if this is the case, would be leaking otherwise")

		chain := j.parent.chain
		j.parent = job.batch(
			job.new1(req, get_dns_records_from_nameserver_job, "get dns from ns cont."),
			job.new2(req.client, DNS_RESPONSE_TIMEOUT, timeout_job, "get dns from ns cont. timeout"),
		)
		j.parent.chain = chain

		// Need to manually clean this job up because we are changing the pointers on our own.
		job.destroy(j.parent, .Single)
		job.destroy(j.batch,  .Single)
		job.destroy(j,        .Single)

		// Because we don't call done on this job, nothing will run anymore, so we have to kick it
		// off again.
		job.run(j.parent)

	case .Run:
		log.info("get_dns_records_from_nameserver_job run")
		c        := req.client
		hostname := req.target.hostname

		// Same request is used across name servers so zero the buffers.
		req.packet_buf   = 0
		req.response_buf = 0

		request_packet: []byte
		{
			hdr := net.DNS_Header{
				is_recursion_desired = true,
			}

			id, bits := net.pack_dns_header(hdr)
			dns_hdr := [6]u16be{}
			dns_hdr[0] = id
			dns_hdr[1] = bits
			dns_hdr[2] = 1

			b := strings.builder_from_slice(req.packet_buf[:])

			strings.write_bytes(&b, mem.slice_data_cast([]u8, dns_hdr[:]))

			assert(net.encode_hostname(&b, hostname), "should already be validated in caller")

			dns_query := [2]u16be{ u16be(net.DNS_Record_Type.IP4), 1}
			strings.write_bytes(&b, mem.slice_data_cast([]u8, dns_query[:]))
			request_packet = req.packet_buf[:strings.builder_len(b)]
		}

		sock, err := nbio.open_socket(&c.io, net.family_from_endpoint(name_server), .UDP)
		if err != nil {
			req.result.err = err

			// TODO: Is cancelling good here?
			job.cancel(j)

			return
		}
		req.sock = sock.(net.UDP_Socket)

		nbio.send_all(&c.io, name_server, req.sock, request_packet, j, req, proc(j: ^job.Job, req: ^DNS_Req, sent: int, err: net.Network_Error) {
			log.info("send_all callback")
			if j.cancelled do return

			if err != nil {
				req.result.err = err
				job.cancel(j)
			}

			if req.name_server_id == 0 {
				job.cancel(j)
			}
		})

		nbio.recv(&c.io, req.sock, req.response_buf[:], j, req, proc(j: ^job.Job, req: ^DNS_Req, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
			log.info("recv callback")
			if j.cancelled do return

			if err != nil {
				req.result.err = err
				job.cancel(j)
				return
			}

			dns_response := req.response_buf[:received]
			rsp, ok := net.parse_response(dns_response, .IP4)
			if !ok {
				req.result.err = net.DNS_Error.Server_Error
				job.cancel(j)
				return
			}

			req.result.records = rsp

			nbio.close(&req.client.io, req.sock)
			job.done(j)
			job.cancel_others_in_batch(j)
		})
	}
}
