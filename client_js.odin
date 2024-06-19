//+private
package http

import "base:runtime"
import "core:fmt"

import "core:slice"

import "nbio"

foreign import "odin_io"

_Client :: struct {
	io:        ^nbio.IO,
	allocator: runtime.Allocator,
}
#assert(offset_of(_Client, io) == 0, "Relied upon in JS")

// TODO: use given IO.
_client_init :: proc(c: ^Client, io: ^nbio.IO, allocator := context.allocator) {
	c.io = io
	c.allocator = allocator
}

@(private="file")
In_Flight :: struct {
	method:           string,
	url:              string,
	headers:          []slice.Map_Entry(string, string),
	body:             []byte,
	ignore_redirects: bool,
	cors:             string,
	credentials:      string,

	res:  Client_Response,
	user: rawptr,
	cb:   On_Response,
	ctx:  runtime.Context,
}

@(private="file")
On_Internal_Response :: #type proc "contextless" (c: ^Client, r: ^In_Flight, err: Request_Error)

_client_request :: proc(c: ^Client, req: Client_Request, user: rawptr, cb: On_Response) {
	foreign odin_io {
		http_request :: proc "contextless" (c: ^Client, r: ^In_Flight, cb: On_Internal_Response) ---
	}

	context.allocator = c.allocator

	r := new(In_Flight)
	r.ctx = context

	r.method  = method_string(req.method)
	r.url = req.url
	// AFAIK iterating a map in JS land is pretty much impossible (without much work).
	r.headers, _ = slice.map_entries(req.headers._kv, /* allocator */)
	r.body = req.body
	r.ignore_redirects = req.ignore_redirects

	switch req.js_cors {
	case .CORS:        r.cors = "cors"
	case .No_CORS:     r.cors = "no-cors"
	case .Same_Origin: r.cors = "same-origin"
	case:              unreachable()
	}

	switch req.js_credentials {
	case .Same_Origin: r.credentials = "same-origin"
	case .Include:     r.credentials = "include"
	case .Omit:        r.credentials = "omit"
	}

	r.user = user
	r.cb = cb

	http_request(c, r, on_response)

	on_response :: proc "contextless" (c: ^Client, r: ^In_Flight, err: Request_Error) {
		context = r.ctx

		delete(r.headers, /* allocator */)

		r.res.headers.readonly = true

		r.cb(r.res, r.user, err)
	}
}

@(private="file", export)
http_alloc :: proc "contextless" (r: ^In_Flight, size: i32) -> rawptr {
	context = r.ctx
	return make([^]byte, size)
}

@(private="file", export)
http_res_header_set :: proc "contextless" (r: ^In_Flight, key: string, value: string) {
	context = r.ctx
	headers_set_unsafe(&r.res.headers, key, value)
}
