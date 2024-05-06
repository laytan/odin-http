// A fully non-blocking DNS client with TTL caching.
package dns

import "core:log"
import "core:mem"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

import nbio "../../nbio/poly"

// TODO: Windows.

// Time we wait for a response from a DNS server.
DNS_SERVER_TIMEOUT :: time.Second
MAX_TTL_SECONDS    :: 60*60

// WARNING: Consider all these fields private.
Client :: struct {
    allocator: mem.Allocator,

	io: ^nbio.IO,

    // Hosts/Name servers configuration.
	name_servers: []net.Endpoint,
	hosts:        []net.DNS_Host_Entry,
	// init_cb:      proc(^Client, rawptr),
	// init_ud:      rawptr,
	// init_state:   int,

    // Cache.
    cache: map[string]Cache_Entry,
}

Record :: struct {
	address:  net.Address,
	ttl_secs: u32,
}

@(private)
Cache_Entry :: struct {
    record:    Record,
    resolving: bool,
    err:       net.Network_Error,
    callbacks: [dynamic]Callback,
    evictor:   ^nbio.Completion,
}

@(private)
Callback :: struct {
    cb: On_Resolve,
    ud: rawptr,
}

// TODO: callback.
init :: proc(c: ^Client, allocator := context.allocator) {
    c.allocator = allocator
    c.cache.allocator = allocator

	load_name_servers(c)
	load_hosts(c)
}

// Waits until all requests are done and frees all related resources.
destroy :: proc {
	destroy_cb,
	destroy_no_cb,
}

destroy_no_cb :: proc(c: ^Client) {
	destroy_cb(c, nil, proc(_: rawptr) {})
}

destroy_cb :: proc(c: ^Client, user: rawptr, cb: proc(user: rawptr)) {
	cache_clear(c)

	// Try to clear again next tick, we don't want to interrupt in progress requests.
	if len(c.cache) > 0 {
		nbio.next_tick(c.io, c, user, cb, destroy_cb)
	} else {
		delete(c.cache)
		delete(c.name_servers, c.allocator)
		for h in c.hosts {
			delete(h.name, c.allocator)
		}
		delete(c.hosts, c.allocator)
		cb(user)
	}
}

// Removes any cache entries that aren't currently being resolved.
cache_clear :: proc(c: ^Client) {
    for hostname, entry in c.cache {
        if entry.resolving do continue
        log.debugf("DNS of %q has been evicted", hostname)

        delete(hostname, c.allocator)
        delete_key(&c.cache, hostname)
        nbio.timeout_remove(c.io, entry.evictor)
    }
}

// Removes the entry (if it exists) for the given hostname from the DNS cache.
cache_evict :: proc(c: ^Client, hostname: string) {
    if entry, ok := c.cache[hostname]; ok {
        log.debugf("DNS of %q has been evicted", hostname)
        delete_key(&c.cache, hostname)
        delete(hostname, c.allocator)
        nbio.timeout_remove(c.io, entry.evictor)
    }
}

// TODO: a shrink cache proc, like `cache_shrink(dns: ^Dns, max_entries: int)` that deletes x randoms.

On_Resolve :: #type proc(user: rawptr, record: Record, err: net.Network_Error)

@(private)
Request :: struct {
	client:      ^Client,
    hostname:    string,
	name_server: int,
	packet:      [net.DNS_PACKET_MIN_LEN]byte,
	packet_len:  int,
	response:    [4096]byte,
	family:      Address_Family,
	socket:      net.UDP_Socket,
	err:         net.Network_Error,
}

Address_Family :: enum {
	None,
	IP4,
	IP6,
}

// Resolve the given hostname to an IP4 or IP6 address.
//
// The given `hostname` string is copied internally and can thus be temporary.
//
// On completion, the request/response is cached for further use, and a timeout is added to the
// event loop to evict the record after the returned time to live.
//
// General Process:
// In the cache?
//   Yes - Still resolving?
//     Yes - Add callback to list of callbacks that are called after resolving
//     No  - Call the callback with DNS record from the cache
//   No - Check for matches in the user's hosts file (`/etc/hosts` for example), is it there?
//     Yes - Call callback with match
//     No  - Start resolving, create in progress cache entry send IP4 request to the first name server
//           retrieved from the user's resolv file (`/etc/resolv.conf` for example)
//           Each name server is given a timeout of `DNS_SERVER_TIMEOUT` to respond,
//           if it doesn't respond or if it fails (error or no result) the next name server is tried.
//           If all name servers haven't returned any result for IP4, the same loop over all name servers
//           is started for IP6. Did any name server respond with an address?
//             Yes - Complete the cache entry and call all queued callbacks,
//                   and add a timeout for the returned time to live (with a `MAX_TTL_SECONDS` maximum)
//                   seconds to the event loop which on completion evicts the record from the cache.
//             No  - Complete the cache entry with an error and call all queued callbacks,
//                   and add a timeout for 1 minute for the record to be evicted from the cache.
resolve :: proc(c: ^Client, hostname: string, user: rawptr, cb: On_Resolve) {
	log.debugf("resolving DNS for %q", hostname)

    if cached, ok := &c.cache[hostname]; ok {
        if cached.resolving {
            log.debugf("already resolving DNS of %q, adding to callback queue", hostname)
            append(&cached.callbacks, Callback{cb, user})
        } else {
            log.debugf("got DNS of %q from cache", hostname)
            cb(user, cached.record, cached.err)
        }
        return
    }

	log.debugf("%q not in cache", hostname)

	for host in c.hosts {
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

	if len(c.name_servers) == 0 {
		log.error("no name servers to query for DNS records")
		cb(user, {}, .Unable_To_Resolve)
		return
	}

	log.debug("querying name servers for IP4 records")

    host  := strings.clone(hostname, c.allocator)

    entry := map_insert(&c.cache, host, Cache_Entry{ resolving = true })
    entry.callbacks = make([dynamic]Callback, 1, c.allocator)
    entry.callbacks[0] = {cb, user}

    req := new(Request, c.allocator)
    req.hostname = host
	req.family   = .IP4

	packet, err := net.make_dns_packet(req.packet[:], hostname, .IP4)
	if err != nil {
		free(req)
		cb(user, {}, err)
		return
	}
	req.packet_len = len(packet)

	req.client = c
	req.name_server = -1

	next(req, nil)

	next :: proc(req: ^Request, err: net.Network_Error) {
		if err != nil {
			log.warnf("name server %v query errored: %v", req.client.name_servers[req.name_server], err)
			req.err = err
		}

		if req.socket != {} {
			log.debug("closing socket of previous name server")
			nbio.close(req.client.io, req.socket)
		}

		req.name_server += 1
		if req.name_server >= len(req.client.name_servers) {
			#partial switch req.family {
			case .IP4:
				log.debug("no DNS results gotten from IP4, querying name servers for IP6")
				req.family = .IP6
				req.name_server = -1
				change_dns_packet_family(req.packet[:req.packet_len], .DNS_TYPE_NS)
				next(req, nil)
			case .IP6:
                entry := &req.client.cache[req.hostname]
                entry.err = .Unable_To_Resolve if req.err == nil else req.err
                entry.resolving = false
				log.warn("no DNS results gotten from IP6 either, calling callbacks with error:", entry.err)

                // Evict the cached error after a minute.
                nbio.timeout(req.client.io, time.Minute, req.client, req.hostname, evict_record)

				free(req)

                for cb in entry.callbacks {
                    cb.cb(cb.ud, {}, entry.err)
                }
                delete(entry.callbacks)
			case:
				unreachable()
			}
			return
		}

		ns := req.client.name_servers[req.name_server]
		family := net.family_from_address(ns.address)

		log.debugf("quering name server %v over %v", ns, family)

		sock, oerr := nbio.open_socket(req.client.io, family, .UDP)
		if oerr != nil {
			log.warnf("could not open UDP socket to name server: %v", oerr)
			next(req, oerr)
			return
		}
		req.socket = sock.(net.UDP_Socket)

		nbio.send_all(req.client.io, ns, req.socket, req.packet[:req.packet_len], req, on_sent)
	}

	on_record :: proc(req: ^Request, rec: Record) {
		log.debug("got DNS record", rec)
		nbio.close(req.client.io, req.socket)

        expires := time.Second*time.Duration(clamp(rec.ttl_secs, 0, MAX_TTL_SECONDS))
        nbio.timeout(req.client.io, expires, req.client, req.hostname, evict_record)

		free(req)

        entry := &req.client.cache[req.hostname]
        entry.resolving = false
        entry.record = rec

        for cb in entry.callbacks {
		    cb.cb(cb.ud, rec, nil)
        }
        delete(entry.callbacks)
	}

    evict_record :: proc(c: ^Client, hostname: string, _: Maybe(time.Time)) {
        if entry, ok := c.cache[hostname]; ok {
            log.debugf("DNS TTL of %vs from %q has expired", entry.record.ttl_secs, hostname)
            delete_key(&c.cache, hostname)
            delete(hostname, c.allocator)
        }
    }

	on_sent :: proc(req: ^Request, n: int, err: net.Network_Error) {
		log.debugf("sent a %m packet with %v err, receiving response", n, err)
		if err != nil {
			next(req, err)
			return
		}

		nbio.with_timeout(req.client.io, DNS_SERVER_TIMEOUT, nbio.recv(req.client.io, req.socket, req.response[:], req, on_recv))
	}

	on_recv :: proc(req: ^Request, sz: int, _: Maybe(net.Endpoint), err: net.Network_Error) {
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
}

// Loads the name servers from the OS, this is called implicitly during `init`.
@(private)
load_name_servers :: proc(c: ^Client) {
	resolv_conf := net.DEFAULT_DNS_CONFIGURATION.resolv_conf
	if resolv_conf == "" {
		log.error("empty resolv_conf file path") // TODO: this is not an error on Windows.
		return
	}

	fd, err := nbio.open(c.io, resolv_conf)
	if err != os.ERROR_NONE {
		log.errorf("error opening %q: %v", resolv_conf, err)
		return
	}

	on_resolv_conf_content :: proc(c: ^Client, fd: os.Handle, buf: []byte, read: int, err: os.Errno) {
		nbio.close(c.io, fd)
		defer delete(buf, c.allocator)

		if err != os.ERROR_NONE {
			log.errorf("error reading resolv_conf: %v", err)
			return
		}

		c.name_servers = net.parse_resolv_conf(string(buf), c.allocator)
		log.debugf("resolv_conf:\n%s\nname_servers:\n%v", string(buf), c.name_servers)
	}

	nbio.read_entire_file(c.io, fd, c, fd, on_resolv_conf_content, c.allocator)
}

// Loads the hosts file from the OS, this is implicitly called during `init`.
@(private)
load_hosts :: proc(c: ^Client) {
	hosts_file := net.DEFAULT_DNS_CONFIGURATION.hosts_file
	if hosts_file == "" {
		log.error("empty hosts file")
		return
	}

	fd, err := nbio.open(c.io, hosts_file)
	if err != os.ERROR_NONE {
		log.errorf("error opening %q: %v", hosts_file, err)
		return
	}

	on_hosts_content :: proc(c: ^Client, fd: os.Handle, buf: []byte, read: int, err: os.Errno) {
		nbio.close(c.io, fd)
		defer delete(buf, c.allocator)

		if err != os.ERROR_NONE {
			log.errorf("error reading hosts file: %v", err)
			return
		}

		c.hosts = net.parse_hosts(string(buf), c.allocator)
		log.debugf("hosts:\n%s\nentries:\n%v", string(buf), c.hosts)
	}

	nbio.read_entire_file(c.io, fd, c, fd, on_hosts_content, c.allocator)
}

@(private)
change_dns_packet_family :: proc(buf: []byte, type: net.DNS_Record_Type) {
	parts := mem.slice_data_cast([]u16be, buf)
	parts[len(parts)-2] = u16be(type)
}

@(private)
parse_record :: proc(packet: []byte, cur_off: ^int) -> (family: Address_Family, rec: Record, ok: bool) {
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

