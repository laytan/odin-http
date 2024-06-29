package http

import "core:net"
import "core:strconv"
import "core:strings"

URL :: struct {
	raw:    string, // All other fields are views/slices into this string.
	scheme: string,
	host:   string,
	path:   string,
	query:  string,
}

url_parse :: proc(raw: string) -> (url: URL) {
	url.raw = raw
	s := raw

	i := strings.index(s, "://")
	if i >= 0 {
		url.scheme = s[:i]
		s = s[i+3:]
	}

	i = strings.index(s, "?")
	if i != -1 {
		url.query = s[i+1:]
		s = s[:i]
	}

	i = strings.index(s, "/")
	if i == -1 {
		url.host = s
	} else {
		url.host = s[:i]
		url.path = s[i:]
	}

    return
}

Query_Entry :: struct {
	key, value: string,
}

query_iter :: proc(query: ^string) -> (entry: Query_Entry, ok: bool) {
	if len(query) == 0 { return }

	ok = true

	i := strings.index(query^, "=")
	if i < 0 {
		entry.key = query^
        query^ = ""
		return
	}

	entry.key = query[:i]
	query^ = query[i+1:]

	i = strings.index(query^, "&")
	if i < 0 {
		entry.value = query^
		query^ = ""
		return
	}

	entry.value = query[:i]
	query^ = query[i+1:]
	return
}

query_get :: proc(url: URL, key: string) -> (val: string, ok: bool) #optional_ok {
	q := url.query
	for entry in #force_inline query_iter(&q) {
		if entry.key == key {
			return entry.value, true
		}
	}
	return
}

query_get_percent_decoded :: proc(url: URL, key: string, allocator := context.temp_allocator) -> (val: string, ok: bool) {
	str := query_get(url, key) or_return
	return net.percent_decode(str, allocator)
}

query_get_bool :: proc(url: URL, key: string) -> (result, set: bool) #optional_ok {
    str := query_get(url, key) or_return
    set = true
    switch str {
    case "", "false", "0", "no":
    case:
        result = true
    }
    return
}

query_get_int :: proc(url: URL, key: string, base := 0) -> (result: int, ok: bool, set: bool) {
    str := query_get(url, key) or_return
    set = true
    result, ok = strconv.parse_int(str, base)
    return
}

query_get_uint :: proc(url: URL, key: string, base := 0) -> (result: uint, ok: bool, set: bool) {
    str := query_get(url, key) or_return
    set = true
    result, ok = strconv.parse_uint(str, base)
    return
}

