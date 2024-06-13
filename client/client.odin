// package client provides a HTTP/1.1 client.
package client

import http ".."
import      "../nbio"

// TODO: Implement a proper cookie jar per client, see rfc.
// it should take response cookies, add it to the jar and automatically add them to matching requests again.
// we can then make use of `js_credentials` on native too.

// TODO: timeouts

Client :: _Client

On_Response :: #type proc(r: Response, user_data: rawptr, err: Request_Error)


Request :: struct {
	method:  http.Method,
	url:     http.URL,
	cookies: []http.Cookie,
	body:    []byte,
	headers: http.Headers,

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
}

Response :: struct {
	status:  http.Status,
	body:    []byte,
	headers: http.Headers,

	// NOTE: unused on JS targets, use the `js_credentials` option to configure cookies there.
	cookies: [dynamic]http.Cookie,
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

init :: proc(c: ^Client, io: ^nbio.IO, allocator := context.allocator) {
	_init(c, io, allocator)
}

request :: proc(c: ^Client, req: Request, user: rawptr, cb: On_Response) {
	_request(c, req, user, cb)
}
