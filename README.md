# Odin HTTP

A HTTP/1.1 server implementation for Odin.

See the example for usage, run the example using: `odin run examples/complete` or `odin run examples/minimal` from the root directory.

**TODO:**
 - max size of request line
 - max size of headers
 - TLS
 - route parameters
 - parsing of URI
 - decompress "Content-Encoding" middleware
 - rate limit middleware
 - Nicer routing
 - Form Data
 - Close idle connections when thread count gets high
 - Thread/connection pool
 - thorough testing (try to break it)
 - profiling
