package http

import "core:net"

@(private)
client_ssl: Client_SSL

set_client_ssl :: proc(ssl: Client_SSL) {
	client_ssl = ssl
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

Client_SSL :: struct {
	implemented:        bool,
	client_create:      proc() -> SSL_Client,
	client_destroy:     proc(client: SSL_Client),
	connection_create:  proc(client: SSL_Client, socket: net.TCP_Socket, host: cstring) -> SSL_Connection,
	connection_destroy: proc(client: SSL_Client, connection: SSL_Connection),
	connect:            proc(c: SSL_Connection) -> SSL_Result,
	send:               proc(c: SSL_Connection, data: []byte) -> (int, SSL_Result),
	recv:               proc(c: SSL_Connection, buf: []byte) -> (int, SSL_Result),
}
