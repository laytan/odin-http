//+build linux, darwin
package client

import "core:net"
import "core:strings"
import "core:log"

// Put callback in queue
// If already requesting dns records, return
// Request dns records
// TODO: if we don't have hosts or resolv loaded, do that first
_new_get_dns_records :: proc(c: ^Client, req: ^DNS_Req, hostname: string, type: net.DNS_Record_Type, user: rawptr, callback: On_DNS_Records) {
	if type != .SRV {
		// NOTE(tetra): 'hostname' can contain underscores when querying SRV records
		ok := net.validate_hostname(hostname)
		if !ok {
			callback(c, user, nil, net.DNS_Error.Invalid_Hostname_Error)
			return
		}
	}

	// TODO: check resolv and hosts.

	host_overrides: [dynamic]net.DNS_Record
	for host in c.hosts {
		if strings.compare(host.name, hostname) != 0 {
			continue
		}

		if type == .IP4 && net.family_from_address(host.addr) == .IP4 {
			record := net.DNS_Record_IP4{
				base = {
					record_name = hostname,
					ttl_seconds = 0,
				},
				address = host.addr.(net.IP4_Address),
			}
			append(&host_overrides, record)
		} else if type == .IP6 && net.family_from_address(host.addr) == .IP6 {
			record := net.DNS_Record_IP6{
				base = {
					record_name = hostname,
					ttl_seconds = 0,
				},
				address = host.addr.(net.IP6_Address),
			}
			append(&host_overrides, record)
		}
	}

	if len(host_overrides) > 0 {
		callback(c, user, host_overrides[:], nil)
		return
	}

	new_get_dns_records_from_nameservers(c, req, hostname, type, user, callback)
}
