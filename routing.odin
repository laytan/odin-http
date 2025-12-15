package http

import "base:runtime"

import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:text/match"

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

	// Per RFC 3986 3.4 the query component can contain both ':' and '/' characters unescaped.
	// Since the scheme may be absent in a HTTP request line, the query should be separated first.
	i := strings.index(s, "?")
	if i != -1 {
		url.query = s[i+1:]
		s = s[:i]
	}

	i = strings.index(s, "://")
	if i >= 0 {
		url.scheme = s[:i]
		s = s[i+3:]
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

	param: string
	i := strings.index(query^, "&")
	if i < 0 {
		param = query^
		query^ = ""
	} else {
		param = query[:i]
		query^ = query[i+1:]
	}

	i = strings.index(param, "=")
	if i < 0 {
		entry.key = param
		entry.value = ""
		return
	}

	entry.key = param[:i]
	entry.value = param[i+1:]

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

Route :: struct {
	handler: Handler,
	pattern: string,
}

Router :: struct {
	allocator: runtime.Allocator,
	routes:    map[Method][dynamic]Route,
	all:       [dynamic]Route,
}

router_init :: proc(router: ^Router, allocator := context.allocator) {
	router.allocator = allocator
	router.routes = make(map[Method][dynamic]Route, len(Method), allocator)
}

router_destroy :: proc(router: ^Router) {
	context.allocator = router.allocator

	for route in router.all {
		delete(route.pattern)
	}
	delete(router.all)

	for _, routes in router.routes {
		for route in routes {
			delete(route.pattern)
		}

		delete(routes)
	}

	delete(router.routes)
}

// Returns a handler that matches against the given routes.
router_handler :: proc(router: ^Router) -> Handler {
	h: Handler
	h.user_data = router

	h.handle = proc(handler: ^Handler, req: ^Request, res: ^Response) {
		router := (^Router)(handler.user_data)
		rline := req.line.(Requestline)

		if routes_try(router.routes[rline.method], req, res) {
			return
		}

		if routes_try(router.all, req, res) {
			return
		}

		log.infof("no route matched %s %s", method_string(rline.method), rline.target)
		res.status = .Not_Found
		respond(res)
	}

	return h
}

route_get :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Get,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_post :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Post,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

// NOTE: this does not get called when `Server_Opts.redirect_head_to_get` is set to true.
route_head :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Head,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_put :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Put,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_patch :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Patch,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_trace :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Trace,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_delete :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Delete,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_connect :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Connect,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

route_options :: proc(router: ^Router, pattern: string, handler: Handler) {
	route_add(
		router,
		.Options,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

// Adds a catch-all fallback route (all methods, ran if no other routes match).
route_all :: proc(router: ^Router, pattern: string, handler: Handler) {
	if router.all == nil {
		router.all = make([dynamic]Route, 0, 1, router.allocator)
	}

	append(
		&router.all,
		Route{handler = handler, pattern = strings.concatenate([]string{"^", pattern, "$"}, router.allocator)},
	)
}

@(private)
route_add :: proc(router: ^Router, method: Method, route: Route) {
	if method not_in router.routes {
		router.routes[method] = make([dynamic]Route, router.allocator)
	}

	append(&router.routes[method], route)
}

@(private)
routes_try :: proc(routes: [dynamic]Route, req: ^Request, res: ^Response) -> bool {
	try_captures: [match.MAX_CAPTURES]match.Match = ---
	for route in routes {
		n, err := match.find_aux(req.url.path, route.pattern, 0, true, &try_captures)
		if err != .OK {
			log.errorf("Error matching route: %v", err)
			continue
		}

		if n > 0 {
			captures := make([]string, n - 1, context.temp_allocator)
			for cap, i in try_captures[1:n] {
				captures[i] = req.url.path[cap.byte_start:cap.byte_end]
			}

			req.url_params = captures
			rh := route.handler
			rh.handle(&rh, req, res)
			return true
		}
	}

	return false
}
