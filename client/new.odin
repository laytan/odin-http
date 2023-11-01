package client

import "core:net"
import "core:os"
import "core:strings"
import "core:bytes"
import "core:mem"
import "core:testing"
import "core:fmt"
import "core:log"

import "../nbio"

@(test)
test_client :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

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
		new_client_init(&c)
		defer new_client_destroy(&c)

		for len(c.name_servers) == 0 {
			errno := nbio.tick(&c.io)
			assert(errno == 0)
		}

		done: bool
		done2: bool
		resolve(&c, "www.google.com", &done, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
			done := cast(^bool)user
			done^ = true

			log.info(ep)
			assert(err == nil)
		})

		resolve(&c, "www.google.com", &done2, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
			done := cast(^bool)user
			done^ = true

			log.info(ep)
			assert(err == nil)
		})

		for !done && !done2 {
			errno := nbio.tick(&c.io)
			assert(errno == 0)
		}
	}
}

DNS :: union {
	^DNS_Req,          // Inflight dns resolve.
	net.Network_Error, // Dns could not be resolved.
	net.Address,       // Resolved endpoint.
}

DNS_Req :: struct {
	client:       ^Client,

	packet_buf:   [(size_of(u16be) * 6) + net.NAME_MAX + (size_of(u16be) * 2)]byte,
	response_buf: [4096]byte,
	sock:         net.UDP_Socket,

	type:         net.DNS_Record_Type,
	target:       net.Host,

	user:         rawptr,
	callback:     On_DNS_Records,

	queue:        [dynamic]DNS_Req_Queue_Entry,
}

DNS_Req_Queue_Entry :: struct {
	user: rawptr,
	cb: On_Resolve,
	port: int,
}

Client :: struct {
	// TODO: keep connections open (configurable).

	// TODO: timeouts.

	io:           nbio.IO,

	dns:          map[string]DNS,

	dns_config:   net.DNS_Configuration,

	hosts_fd:     os.Handle,
	hosts_buf:    []byte,
	hosts:        []net.DNS_Host_Entry,

	resolv_fd:    os.Handle,
	resolv_buf:   []byte,
	name_servers: []net.Endpoint,
}

new_client_init :: proc(c: ^Client) {
	c.dns_config = net.dns_configuration
	nbio.init(&c.io)

	err := new_load_hosts(c)
	assert(err == 0)

	errb := new_load_resolv_conf(c)
	assert(errb == 0)

	// TODO: what if no name servers or error.
	// TODO: what if hosts file loads after resolv (race condition).
	for len(c.name_servers) == 0 {
		errno := nbio.tick(&c.io)
		assert(errno == 0)
	}
}

new_client_destroy :: proc(c: ^Client) {
	nbio.destroy(&c.io)

	delete(c.name_servers)
	delete(c.hosts_buf)
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
		// TODO: send both ip4 and ip6 reqs and use first response.

		if dns, ok := c.dns[t.hostname]; ok {
			switch d in dns {
			case net.Network_Error:
				callback(c, user, {}, d)
				return
			case net.Address:
				callback(c, user, net.Endpoint{d, t.port}, nil)
				return
			case ^DNS_Req:
				log.debug("queue")
				append(&d.queue, DNS_Req_Queue_Entry{cb = callback, user = user, port = t.port})
			}
			return
		}

		req := new(DNS_Req)
		req.target = t

		c.dns[t.hostname] = req

		append(&req.queue, DNS_Req_Queue_Entry{cb = callback, user = user, port = t.port})

		new_get_dns_records(c, req, t.hostname, .IP4, req, proc(c: ^Client, user: rawptr, records: []net.DNS_Record, err: net.Network_Error) {
			req := cast(^DNS_Req)user
			err := err

			if err == nil && len(records) == 0 {
				err = net.Resolve_Error.Unable_To_Resolve
			}

			if err != nil {
				c.dns[req.target.hostname] = err
				for e in req.queue {
					e.cb(req.client, e.user, {}, err)
				}
				delete(req.queue)
				return
			}

			address: net.Address = records[0].(net.DNS_Record_IP4).address

			req.client.dns[req.target.hostname] = address

			// Kind of a waste, we don't use it or any more than 1 returned record.
			for rcrd in records {
				delete(rcrd.(net.DNS_Record_IP4).record_name)
			}
			delete(records)

			for e in req.queue {
				e.cb(req.client, e.user, {address = address, port = e.port}, nil)
			}
			delete(req.queue)
			free(req)
		})

		// TODO: also do ip6

		// resolve_ip4(c, req, t.hostname, req, proc(c: ^Client, user: rawptr, ep: net.Endpoint, err: net.Network_Error) {
		// 	req := cast(^DNS_Req)user
		// 	c   := cast(^Client)req.client
		//
		// 	req.resolve_callback(c, req.resolve_user, ep, err)
		// 	free(req)
		// })
		// // if err4 == nil {
		// // 	ep = ep4
		// // 	ep.port = t.port
		// // 	return
		// // }
		//
		// // ep6, err6 := resolve_ip6(c, t.hostname)
		// // if err6 == nil {
		// // 	ep = ep6
		// // 	ep.port = t.port
		// // 	return
		// // }

		return
	}
	unreachable()
}

// resolve_ip6 :: proc(c: ^Client, hostname_and_maybe_port: string) -> (ep6: net.Endpoint, err: net.Network_Error) {
// 	target := net.parse_hostname_or_endpoint(hostname_and_maybe_port) or_return
// 	switch t in target {
// 	case net.Endpoint:
// 		// NOTE(tetra): The hostname was actually an IP address; nothing to resolve, so just return it.
// 		switch _ in t.address {
// 		case net.IP4_Address:
// 			err = .Unable_To_Resolve
// 			return
// 		case net.IP6_Address:
// 			return t, nil
// 		}
// 	case net.Host:
// 		recs, _ := new_get_dns_records(t.hostname, .IP6, context.temp_allocator)
// 		if len(recs) == 0 {
// 			err = .Unable_To_Resolve
// 			return
// 		}
// 		ep6 = {
// 			address = recs[0].(net.DNS_Record_IP6).address,
// 			port = t.port,
// 		}
// 		return
// 	}
// 	unreachable()
// }

new_load_hosts :: proc(c: ^Client) -> (err: os.Errno) {
	c.hosts_fd, err = nbio.open(&c.io, c.dns_config.hosts_file)
	if err != os.ERROR_NONE do return

	c.hosts_buf = nbio.read_entire_file(&c.io, c.hosts_fd, c, proc(user: rawptr, read: int, err: os.Errno) {
		c := cast(^Client)user

		nbio.close(&c.io, c.hosts_fd)
		c.hosts_fd = os.INVALID_HANDLE

		// TODO: handle errors
		assert(err == os.ERROR_NONE)
		assert(read == len(c.hosts_buf))

		hosts_str := string(c.hosts_buf)
		hosts := make([dynamic]net.DNS_Host_Entry)
		for line in strings.split_lines_iterator(&hosts_str) {
			line := line

			if len(line) == 0 || line[0] == '#' {
				continue
			}

			first_iter := true
			addr: net.Address
			for field in strings.fields_iterator(&line) {
				if first_iter {
					first_iter = false
					addr = net.parse_address(field)
					if addr == nil do break
				} else {
					if len(field) > 0 {
						append(&hosts, net.DNS_Host_Entry{field, addr})
					}
				}
			}
		}

		c.hosts = hosts[:]
	})

	return
}

new_load_resolv_conf :: proc(c: ^Client) -> (err: os.Errno) {
	c.resolv_fd, err = nbio.open(&c.io, c.dns_config.resolv_conf)
	if err != os.ERROR_NONE do return

	c.resolv_buf = nbio.read_entire_file(&c.io, c.resolv_fd, c, proc(user: rawptr, read: int, err: os.Errno) {
		c := cast(^Client)user

		nbio.close(&c.io, c.resolv_fd)
		c.resolv_fd = os.INVALID_HANDLE

		defer delete(c.resolv_buf)

		// TODO: handle errors
		assert(err == os.ERROR_NONE)
		assert(read == len(c.resolv_buf))

		resolv_str := string(c.resolv_buf)
		id_str :: "nameserver"
		id_len :: len(id_str)

		name_servers := make([dynamic]net.Endpoint)
		for line in strings.split_lines_iterator(&resolv_str) {
			if len(line) == 0 || line[0] == '#' {
				continue
			}

			if len(line) < id_len || strings.compare(line[:id_len], id_str) != 0 {
				continue
			}

			server_ip_str := strings.trim_left_space(line[id_len:])
			if len(server_ip_str) == 0 {
				continue
			}

			addr := net.parse_address(server_ip_str)
			if addr == nil {
				continue
			}

			append(&name_servers, net.Endpoint{addr, 53})
		}

		c.name_servers = name_servers[:]
	})

	return
}

On_DNS_Records :: #type proc(c: ^Client, user: rawptr, records: []net.DNS_Record, err: net.Network_Error)

// TODO: cache result for hostname and type combination
// Put callback in queue
// If already requesting dns records, return
// Request dns records
// TODO: if we don't have hosts or resolv loaded, do that first
new_get_dns_records :: proc(c: ^Client, req: ^DNS_Req, hostname: string, type: net.DNS_Record_Type, user: rawptr, callback: On_DNS_Records) {
	_new_get_dns_records(c, req, hostname, type, user, callback)
}

new_get_dns_records_from_nameservers :: proc(c: ^Client, req: ^DNS_Req, hostname: string, type: net.DNS_Record_Type, user: rawptr, callback: On_DNS_Records) {
	if type != .SRV {
		// NOTE(tetra): 'hostname' can contain underscores when querying SRV records
		ok := net.validate_hostname(hostname)
		if !ok {
			callback(c, user, nil, net.DNS_Error.Invalid_Hostname_Error)
			return
		}
	}

	req.client = c
	req.type = type
	req.user = user
	req.callback = callback

	hdr := net.DNS_Header{
		is_recursion_desired = true,
	}

	id, bits := net.pack_dns_header(hdr)
	dns_hdr := [6]u16be{}
	dns_hdr[0] = id
	dns_hdr[1] = bits
	dns_hdr[2] = 1

	dns_query := [2]u16be{ u16be(type), 1 }

	b := strings.builder_from_slice(req.packet_buf[:])

	strings.write_bytes(&b, mem.slice_data_cast([]u8, dns_hdr[:]))
	ok := net.encode_hostname(&b, hostname)
	if !ok {
		callback(c, user, nil, net.DNS_Error.Invalid_Hostname_Error)
		return
	}
	strings.write_bytes(&b, mem.slice_data_cast([]u8, dns_query[:]))

	// TODO:
	// send each name_server the dns request, at the first response, stop everything else.

	name_server := c.name_servers[0]

	sock, err := nbio.open_socket(&c.io, net.family_from_endpoint(name_server), .UDP)
	if err != nil {
		callback(c, user, nil, err)
		return
	}
	req.sock = sock.(net.UDP_Socket)

	nbio.send_all(
		&c.io,
		name_server,
		req.sock,
		req.packet_buf[:strings.builder_len(b)],
		req,
		proc(user: rawptr, sent: int, err: net.Network_Error) {
			req := cast(^DNS_Req)user
			c   := req.client

			// TODO:
			assert(sent > 0)
			assert(err == nil)

			nbio.recv(
				&c.io,
				req.sock,
				req.response_buf[:],
				req,
				proc(user: rawptr, received: int, udp_client: Maybe(net.Endpoint), err: net.Network_Error) {
					req := cast(^DNS_Req)user
					c   := req.client

					// TODO:
					assert(received > 0)
					assert(err == nil)

					dns_response := req.response_buf[:received]
					rsp, ok := net.parse_response(dns_response, req.type)

					// TODO:
					assert(ok)
					assert(len(rsp) > 0)

					req.callback(c, req.user, rsp, nil)
				},
			)
		},
	)
}
