package websocket


client_target :: proc(http_client: ^client.Client, target: string) {
}

client_url :: proc(http_client: ^client.Client, url: http.URL) {

	// make upgrade request,
	// on response, call open

	// in http client, if upgrade request, leave the connection alone after successful upgrade

}

client :: proc {
	client_target,
	client_url,
}

