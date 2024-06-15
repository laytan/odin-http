// package client provides a HTTP/1.1 client.
package http

import "nbio"

// TODO: Implement a proper cookie jar per client, see rfc.
// it should take response cookies, add it to the jar and automatically add them to matching requests again.
// we can then make use of `js_credentials` on native too.

// TODO: timeouts

Client :: _Client

On_Response :: #type proc(r: Client_Response, user_data: rawptr, err: Request_Error)

Client_Request :: struct {
	method:  Method,
	url:     URL,
	cookies: []Cookie,
	body:    []byte,
	headers: Headers,

	// TODO: implement on native.
	ignore_redirects: bool,

	js_cors:        JS_CORS_Mode,
	js_credentials: JS_Credentials,
}

// WARN: DO NOT change the layout of this enum or the following struct without at least make sure you didn't break the JS implementation!

Request_Error :: enum {
	None,
	Bad_URL,
	Network,
	CORS,
	Timeout,
	Aborted,
	Unknown,
	DNS,
}

Client_Response :: struct {
	status:  Status,
	body:    []byte,
	headers: Headers,

	// NOTE: unused on JS targets, use the `js_credentials` option to configure cookies there.
	cookies: [dynamic]Cookie,
}

JS_CORS_Mode :: enum {
	CORS,
	No_CORS,
	Same_Origin,
}

// Policy for including and taking credentials (cookies, etc.) from responses and adding them to requests.
JS_Credentials :: enum {
	Same_Origin, // Include credentials only when requesting to the same origin.
	Include,     // Always include credentials.
	Omit,        // Never include credentials.
}

client_init :: proc(c: ^Client, io: ^nbio.IO, allocator := context.allocator) {
	_client_init(c, io, allocator)
}

client_request :: proc(c: ^Client, req: Client_Request, user: rawptr, cb: On_Response) {
	_client_request(c, req, user, cb)
}
