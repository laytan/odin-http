# TODO

- [ ] Make sure everything runs under `-sanitize:thread` and `-sanitize:address`

## HTTP Server

- [ ] Consider switching the temp allocator back again to the custom `allocator.odin`, or remove it
- [ ] Set (more) timeouts
- [x] `http.io()` that returns `&http.td.io` or errors if it isn't one of the handler threads
- [ ] `panic` when user does `free_all` on the given temp ally
- [ ] in `http.respond`, set the `context.temp_allocator` back to the current connection's, so a user changing it doesn't fuck it up

## HTTP Client

- [ ] Proper error propagation
	- [ ] Dispose of a connection where an error happened (network error or 500 error (double check in RFC))
	- [ ] If there are queued requests, spawn a new connection for them
	- [ ] If a connection is closed by the server, how does it get handled, retry configuration?
- [ ] Expand configuration
    - [ ] Max response size
	- [ ] Timeouts
- [x] Create a thin VTable interface for the OpenSSL functionality (so we can put openSSL in vendor and the rest in core)
- [ ] Synchronous API (just take over the `nbio` event loop until the request is done)
- [ ] API that takes over event loop until all pending requests are completed
- [ ] Poly API
- [ ] Testing
	- [ ] Big requests > 16kb (a TLS packet)
- [x] Consider move into main package, but may be confusing?
- [ ] Each host has multiple connections, when a request is made, get an available connection or make a new connection.

## DNS Client

- [ ] Windows

## nbio

- [ ] Implement `with_timeout` everywhere
- [ ] Make sure all procs are implemented everywhere (UDP & TCP, all platforms)
- [ ] Make `with_timeout` more efficient
- [x] Move the sub /poly package into the main one
- [x] Remove toggling the poly API
- [x] JS implementation
- [x] nbio.run that loops a tick, and returns when the event loop has nothing going on
- [ ] remove `read` and `write` and force the offset, document why (Windows)
- [ ] do `time.now` at most once a tick (cache it)

## WebSocket Server

- [ ] Make sending to a connection fully thread-safe (so you can send to a connection from a different thread)
- [ ] Destroy procs
- [ ] Actually use given allocator

## WebSocket Client

- [ ] Implement
- [ ] Reuse code between server and client

# Non critical wants

- [ ] Get on framework benchmarks (can leave out DB tests (if I can't figure out why what I was doing is slow) I think)
- [ ] Support the BSDs

## HTTP Server

- [ ] Add an API to set a custom temp allocator
- [ ] Overload the router procs so you can do `route_get("/foo", foo)` instead of `route_get("/foo", http.handler(foo))`
- [ ] A way to say: "get the body before calling this handler"
- [ ] An API to write directly to the underlying socket, (to not have the overhead of buffering the body in memory)

## HTTP Client

- [ ] Follow redirects
- [ ] Ingest cookies / Cookie JAR
- [ ] Nice APIS wrapping over all the configuration for common actions

## WASM

- [x] HTTP Client backed by JS/WASM (This may have to be an additional, even higher level API, or, have the HTTP API be full of opaque structs and have getters)
- [ ] WebSocket Client backed by JS/WASM
