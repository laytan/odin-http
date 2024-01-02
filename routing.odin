package http

import "core:log"
import "core:net"
import "core:runtime"
import "core:strings"
import "core:text/match"

URL :: struct {
	raw:     string, // All other fields are views/slices into this string.
	scheme:  string,
	host:    string,
	path:    string,
	// TODO/PERF: remove, add a simple string called 'search_params', and provide a procedure to
	// turn it into a map, saves having to allocate and parse for every request.
	// url_parse won't have to allocate then either.
	queries: map[string]string,
}

url_parse :: proc(raw: string, allocator := context.allocator) -> URL {
	url: URL
	url.raw = raw
	url.scheme, url.host, url.path, url.queries = net.split_url(raw, allocator)
	return url
}

url_string :: proc(url: URL, allocator := context.allocator) -> string {
	return net.join_url(url.scheme, url.host, url.path, url.queries, allocator)
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
