package http

import "core:net"

URL :: struct {
	raw:     string, // All other fields are views/slices into this string.
	scheme:  string,
	host:    string,
	path:    string,
	queries: map[string]string,
}

url_parse :: proc(raw: string, allocator := context.allocator) -> URL {
	url: URL
	url.raw = raw
	url.scheme, url.host, url.path, url.queries = net.split_url(raw, allocator)
	return url
}
