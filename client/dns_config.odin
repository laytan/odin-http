package client

import "core:net"
import "core:os"
import "core:strings"
import "core:fmt"
import "core:log"

import nbio "../nbio/poly"
import job "../job"

// TODO: errors.
load_resolv_conv_job :: proc(j: ^job.Job, m: job.Handle_Mode, c: ^Client) {
	switch m {
	case .Cancel:
		nbio.close(&c.io, c.resolv_fd)
		job.done(j)

	case .Run:
		err: os.Errno
		c.resolv_fd, err = nbio.open(&c.io, c.resolv_file_path)
		if err != os.ERROR_NONE do fmt.panicf("error code opening resolv.conf: %i", err)

		nbio.read_entire_file(&c.io, c.resolv_fd, c, j, proc(c: ^Client, j: ^job.Job, buf: []byte, read: int, err: os.Errno) {
			if j.cancelled do return
			defer job.done(j)
			defer log.debug("calling done for load_resolv_conv_job")

			nbio.close(&c.io, c.resolv_fd)
			c.resolv_fd = os.INVALID_HANDLE

			defer delete(buf)

			// TODO: handle errors
			assert(err == os.ERROR_NONE)
			assert(read == len(buf))

			resolv_str := string(buf)
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
	}
}

// TODO: errors.
load_hosts_job :: proc(j: ^job.Job, m: job.Handle_Mode, c: ^Client) {
	switch m {
	case .Cancel:
		nbio.close(&c.io, c.hosts_fd)
		job.done(j)

	case .Run:
		err: os.Errno
		c.hosts_fd, err = nbio.open(&c.io, c.hosts_file_path)
		if err != os.ERROR_NONE do fmt.panicf("error code opening hosts file: %i", err)

		nbio.read_entire_file(&c.io, c.hosts_fd, c, j, proc(c: ^Client, j: ^job.Job, buf: []byte, read: int, err: os.Errno) {
			if j.cancelled do return

			defer job.done(j)
			defer log.debug("calling done for load_hosts_job")

			nbio.close(&c.io, c.hosts_fd)
			c.hosts_fd = os.INVALID_HANDLE

			defer delete(buf)

			// TODO: handle errors
			assert(err == os.ERROR_NONE)
			assert(read == len(buf))

			hosts_str := string(buf)
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
							append(&hosts, net.DNS_Host_Entry{
								strings.clone(field),
								addr,
							})
						}
					}
				}
			}

			c.hosts = hosts[:]
		})
	}
}
