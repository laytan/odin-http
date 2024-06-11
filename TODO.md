# TODO

- [ ] TESTS TESTS TESTS
	- [ ] Can we run the autobahn tests in CI, don't think so?
- [ ] Get on framework benchmarks (can leave out DB tests (if I can't figure out why what I was doing is slow) I think)
- [ ] Make sure everything runs under `-sanitize:thread` and `-sanitize:address`

## HTTP Server

- [ ] Consider switching the temp allocator back again to the custom `allocator.odin`, or remove it
- [ ] Add an API to set a custom temp allocator
- [ ] Set (more) timeouts
- [ ] Overload the router procs so you can do `route_get("/foo", foo)` instead of `route_get("/foo", http.handler(foo))`
- [ ] `http.io()` that returns `&http.td.io` or errors if it isn't one of the handler threads

## HTTP Client

- [ ] Proper error propagation
	- [ ] Dispose of a connection where an error happened (network error or 500 error (double check in RFC))
	- [ ] If there are queued requests, spawn a new connection for them
	- [ ] If a connection is closed by the server, how does it get handled, retry configuration?
- [ ] Expand configuration
	- [ ] Max body length
	- [ ] Max header size
	- [ ] Timeouts
	- [ ] Follow redirects
	- [ ] Ingest cookies
- [ ] Create a thin VTable interface for the OpenSSL functionality (so we can put openSSL in vendor and the rest in core)
- [ ] Synchronous API (just take over the `nbio` event loop until the request is done)
- [ ] Poly API
- [ ] Testing
	- [ ] Big requests > 16kb (a TLS packet)
- [ ] Nice APIS wrapping over all the configuration
- [ ] Move into main package?

## DNS Client

- [ ] Windows

## nbio

- [ ] Implement `with_timeout` everywhere
- [ ] Make sure all procs are implemented everywhere (UDP & TCP, all platforms)
- [ ] Make `with_timeout` more efficient
- [ ] Move the sub /poly package into the main one
- [ ] Remove toggling the poly API
- [ ] `#no_bounds_check` the poly API

## WebSocket Server

- [ ] Make sending to a connection fully thread-safe (so you can send to a connection from a different thread)
- [ ] Destroy procs
- [ ] Actually use given allocator

## WebSocket Client

- [ ] Implement
- [ ] Reuse code between server and client
- [ ] WASM back-end

## WASM

- [ ] HTTP Client backed by JS/WASM (This may have to be an additional, even higher level API, or, have the HTTP API be full of opaque structs and have getters)
- [ ] WebSocket Client backed by JS/WASM
