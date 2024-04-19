package client

import "core:log"
import "core:net"
import "core:os"
import "core:mem"
import "core:time"

import nbio "../nbio/poly"

Dns :: struct {
	io: ^nbio.IO,

	using config: net.DNS_Configuration,

	hosts: []net.DNS_Host_Entry,
}

init_dns :: proc(dns: ^Dns) {
	load_resolv_conv(dns)
	load_hosts(dns)
}

load_resolv_conv :: proc(dns: ^Dns) {
	if dns.resolv_conf == "" {
		log.error("empty resolv_conf file path")
		return
	}

	fd, err := nbio.open(dns.io, dns.resolv_conf)
	if err != os.ERROR_NONE {
		log.errorf("error opening %q: %v", dns.resolv_conf, err)
		return
	}

	on_resolv_conf_content :: proc(dns: ^Dns, fd: os.Handle, buf: []byte, read: int, err: os.Errno) {
		nbio.close(dns.io, fd)
		defer delete(buf)

		if err != os.ERROR_NONE {
			log.errorf("error reading resolv_conf: %v", err)
			return
		}

		dns.name_servers = net.parse_resolv_conf(string(buf), context.allocator)
		log.debugf("resolv_conf:\n%s\nname_servers:\n%v", string(buf), dns.name_servers)
	}

	nbio.read_entire_file(dns.io, fd, dns, fd, on_resolv_conf_content, context.allocator)
}

load_hosts :: proc(dns: ^Dns) {
	if dns.hosts_file == "" {
		log.error("empty hosts file")
		return
	}

	fd, err := nbio.open(dns.io, dns.hosts_file)
	if err != os.ERROR_NONE {
		log.errorf("error opening %q: %v", dns.hosts_file, err)
		return
	}

	on_hosts_content :: proc(dns: ^Dns, fd: os.Handle, buf: []byte, read: int, err: os.Errno) {
		nbio.close(dns.io, fd)
		defer delete(buf)

		if err != os.ERROR_NONE {
			log.errorf("error reading hosts file: %v", err)
			return
		}

		dns.hosts = net.parse_hosts(string(buf), context.allocator)
		log.debugf("hosts:\n%s\nentries:\n%v", string(buf), dns.hosts)
	}

	nbio.read_entire_file(dns.io, fd, dns, fd, on_hosts_content, context.allocator)
}

// NOTE: the record will not have the `record_name` set.
On_Resolve :: #type proc(user: rawptr, record: DNS_Record, err: net.Network_Error)

Dns_Request :: struct {
	dns:         ^Dns,
	name_server: int,
	packet:      [net.DNS_PACKET_MIN_LEN]byte,
	packet_len:  int,
	response:    [4096]byte,
	family:      Address_Family,
	socket:      net.UDP_Socket,
	err:         net.Network_Error,
	cb:          On_Resolve,
	user:        rawptr,
}

DNS_Record :: struct {
	address:  net.Address,
	ttl_secs: u32,
}

DNS_Records :: [net.Address_Family]DNS_Record

Address_Family :: enum {
	None,
	IP4,
	IP6,
}

// resolve :: proc(req: ^Dns_Request, hostname: string, user: rawptr, cb: On_Resolve) {
	// context.user_ptr   = user
	// context.user_index = int(uintptr(rawptr(cb)))
	// resolve_family(req, hostname, .IP4, req, proc(req: rawptr, record: DNS_Record, err: net.Network_Error) {
	// 	user := context.user_ptr
	// 	cb   := On_Resolve(rawptr(uintptr(context.user_index)))
	// 	if err != nil || record != {} {
	// 		cb(user, record, err)
	// 		return
	// 	}
	// })
// }

resolve :: proc(dns: ^Dns, hostname: string, user: rawptr, cb: On_Resolve) {
	log.debugf("resolving DNS for %q", hostname)
	for host in dns.hosts {
		if host.name != hostname {
			continue
		}

		switch addr in host.addr {
		case net.IP4_Address:
			cb(user, { address = host.addr.(net.IP4_Address) }, nil)
			return
		case net.IP6_Address:
			cb(user, { address = host.addr.(net.IP6_Address) }, nil)
			return
		}
	}

	log.debugf("%q not in hosts file", hostname)

	if len(dns.name_servers) == 0 {
		log.warn("no name servers to query for DNS records")
		cb(user, {}, nil)
		return
	}

	log.debug("querying name servers for IP4 records")

	req := new(Dns_Request)
	req.family = .IP4
	req.cb     = cb
	req.user   = user

	packet, err := net.make_dns_packet(req.packet[:], hostname, .IP4)
	if err != nil {
		free(req)
		cb(user, {}, err)
		return
	}
	req.packet_len = len(packet)

	req.dns = dns
	req.name_server = -1

	next :: proc(req: ^Dns_Request, err: net.Network_Error) {
		if err != nil {
			log.warnf("name server %v query errored: %v", req.dns.name_servers[req.name_server], err)
			req.err = err
		}

		if req.socket != {} {
			log.debug("closing socket of previous name server")
			nbio.close(req.dns.io, req.socket)
		}

		req.name_server += 1
		if req.name_server >= len(req.dns.name_servers) {
			#partial switch req.family {
			case .IP4:
				log.debug("no DNS results gotten from IP4, querying name servers for IP6")
				req.family = .IP6
				req.name_server = -1
				change_dns_packet_family(req.packet[:req.packet_len], .DNS_TYPE_NS)
				next(req, nil)
			case .IP6:
				log.debug("no DNS results gotten from IP6 either")
				free(req)
				req.cb(req.user, {}, req.err)
			case:
				unreachable()
			}
			return
		}

		ns := req.dns.name_servers[req.name_server]
		family := net.family_from_address(ns.address)

		log.debugf("quering name server %v over %v", ns, family)

		sock, oerr := nbio.open_socket(req.dns.io, family, .UDP)
		if oerr != nil {
			log.warnf("could not open UDP socket to name server: %v", oerr)
			next(req, oerr)
			return
		}
		req.socket = sock.(net.UDP_Socket)

		nbio.send_all(req.dns.io, ns, req.socket, req.packet[:req.packet_len], req, on_sent)
	}

	on_record :: proc(req: ^Dns_Request, rec: DNS_Record) {
		log.debug("got DNS record %v", rec)
		nbio.close(req.dns.io, req.socket)
		free(req)
		req.cb(req.user, rec, nil)
	}

	on_sent :: proc(req: ^Dns_Request, n: int, err: net.Network_Error) {
		log.debugf("sent a %m packet with %v err, receiving response", n, err)
		if err != nil {
			next(req, err)
			return
		}

		// if oerr := net.set_option(req.socket, .Receive_Timeout, time.Second * 1); oerr != nil {
		// 	log.errorf("error setting timeout on recv: %v", oerr)
		// 	next(req, oerr)
		// 	return
		// }

		nbio.recv(req.dns.io, req.socket, req.response[:], req, on_recv)
	}

	on_recv :: proc(req: ^Dns_Request, sz: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
		log.debugf("received a %m packet with %v err, parsing", sz, err)
		if err != nil {
			next(req, err)
			return
		}

		if sz == 0 {
			next(req, nil)
			return
		}

		response := req.response[:sz]

		HEADER_SIZE_BYTES :: 12
		if sz < HEADER_SIZE_BYTES {
			next(req, nil)
			return
		}

		dns_hdr_chunks := mem.slice_data_cast([]u16be, response[:HEADER_SIZE_BYTES])
		hdr := net.unpack_dns_header(dns_hdr_chunks[0], dns_hdr_chunks[1])
		if !hdr.is_response {
			next(req, nil)
			return
		}

		question_count := int(dns_hdr_chunks[2])
		if question_count != 1 {
			next(req, nil)
			return
		}

		answer_count     := int(dns_hdr_chunks[3])
		authority_count  := int(dns_hdr_chunks[4])
		additional_count := int(dns_hdr_chunks[5])

		cur_idx := HEADER_SIZE_BYTES

		dq_sz :: 4
		hn_sz, hs_ok := net.skip_hostname(response, cur_idx)
		if !hs_ok {
			next(req, nil)
			return
		}
		cur_idx += hn_sz + dq_sz

		for _ in 0..<answer_count+authority_count+additional_count {
			if cur_idx == len(response) {
				continue
			}

			family, rec, ok := parse_record(response, &cur_idx)
			if !ok {
				next(req, nil)
				return
			}

			if family == req.family {
				on_record(req, rec)
				return
			}
		}

		next(req, nil)
	}

	next(req, nil)
}

change_dns_packet_family :: proc(buf: []byte, type: net.DNS_Record_Type) {
	parts := mem.slice_data_cast([]u16be, buf)
	parts[len(parts)-2] = u16be(type)
}

parse_record :: proc(packet: []byte, cur_off: ^int) -> (family: Address_Family, rec: DNS_Record, ok: bool) {
	record_buf := packet[cur_off^:]

	hn_sz := net.skip_hostname(packet, cur_off^) or_return

	ahdr_sz := size_of(net.DNS_Record_Header)
	if len(record_buf) - hn_sz < ahdr_sz {
		return
	}

	record_hdr_bytes := record_buf[hn_sz:hn_sz+ahdr_sz]
	record_hdr := cast(^net.DNS_Record_Header)raw_data(record_hdr_bytes)

	data_sz := record_hdr.length
	data_off := cur_off^ + int(hn_sz) + int(ahdr_sz)
	data := packet[data_off:data_off+int(data_sz)]
	cur_off^ += int(hn_sz) + int(ahdr_sz) + int(data_sz)

	_record: DNS_Record
	#partial switch net.DNS_Record_Type(record_hdr.type) {
	case .IP4:
		if len(data) != 4 {
			return
		}

		addr := (^net.IP4_Address)(raw_data(data))^
		return .IP4, {
			address  = addr,
			ttl_secs = u32(record_hdr.ttl),
		}, true

	case .IP6:
		if len(data) != 16 {
			return
		}

		addr := (^net.IP6_Address)(raw_data(data))^
		return .IP6, {
			address  = addr,
			ttl_secs = u32(record_hdr.ttl),
		}, true

	case:
		return nil, {}, true
	}
}

