package client

import "core:net"

_new_get_dns_records :: proc(c: ^Client, hostname: string, type: net.DNS_Record_Type, user: rawptr, callback: On_DNS_Records) {
	unimplemented()
}
