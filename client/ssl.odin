package client

import "core:net"

@(private)
ssl_implementation: SSL

set_ssl_implementation :: proc(ssl: SSL) {
	ssl_implementation = ssl
}

SSL_Client     :: distinct rawptr
SSL_Connection :: distinct rawptr

SSL_Result :: enum {
	None,
	Want_Read,
	Want_Write,
	Shutdown,
	Fatal,
}

SSL :: struct {
	implemented:       bool,
	client_create:     proc() -> SSL_Client,
	connection_create: proc(client: SSL_Client, socket: net.TCP_Socket, host: cstring) -> SSL_Connection,
	connect:           proc(c: SSL_Connection) -> SSL_Result,
	send:              proc(c: SSL_Connection, data: []byte) -> (int, SSL_Result),
	recv:              proc(c: SSL_Connection, buf: []byte) -> (int, SSL_Result),
}
