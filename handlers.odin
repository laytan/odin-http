package http

import "core:time"
import "core:log"
import "core:net"
import "core:sync"
import "core:strconv"
import "core:bytes"

Handler_Proc :: proc(handler: ^Handler, req: ^Request, res: ^Response)
Handle_Proc :: proc(req: ^Request, res: ^Response)

Handler :: struct {
	user_data: rawptr,
	next:      Maybe(^Handler),
	handle:    Handler_Proc,
}

handler :: proc(handle: Handle_Proc) -> Handler {
	h: Handler
	h.user_data = rawptr(handle)

	handle := proc(h: ^Handler, req: ^Request, res: ^Response) {
		p := (Handle_Proc)(h.user_data)
		p(req, res)
	}

	h.handle = handle
	return h
}

middleware_proc :: proc(next: Maybe(^Handler), handle: Handler_Proc) -> Handler {
	h: Handler
	h.next = next
	h.handle = handle
	return h
}

Logger_Opts :: struct {
	log_time: bool,
}

Default_Logger_Opts := Logger_Opts {
	log_time = false,
}

middleware_logger :: proc(next: Maybe(^Handler), opts: ^Logger_Opts = nil) -> Handler {
	h: Handler
	h.user_data = opts != nil ? opts : &Default_Logger_Opts
	h.next = next

	handle := proc(h: ^Handler, req: ^Request, res: ^Response) {
		opts := (^Logger_Opts)(h.user_data)
		rline := req.line.(Requestline)

		start: time.Tick
		if opts.log_time do start = time.tick_now()

		defer {
			method_str := method_string(rline.method)
			switch opts.log_time {
			case true:
				durqs := time.duration_microseconds(time.tick_since(start))
				log.infof("[%i|%.1fqs] %s %s", res.status, durqs, method_str, rline.target)
			case:
				log.infof("[%i] %s %s", res.status, method_str, rline.target)
			}
		}

		switch n in h.next {
		case ^Handler: n.handle(n, req, res)
		case: log.warn("middleware_logger does not have a next handler")
		}
	}

	h.handle = handle
	return h
}

Rate_Limit_On_Limit :: struct {
	user_data: rawptr,
	on_limit:  proc(req: ^Request, res: ^Response, user_data: rawptr),
}

// Convenience method to create a Rate_Limit_On_Limit that writes the given message.
on_limit_message :: proc(message: ^string) -> Rate_Limit_On_Limit {
	return Rate_Limit_On_Limit{
        user_data = message,
        on_limit = proc(_: ^Request, res: ^Response, user_data: rawptr) {
            message := (^string)(user_data)
            bytes.buffer_write_string(&res.body, message^)
        },
    }
}

Rate_Limit_Opts :: struct {
	window:   time.Duration,
	max:      int,

	// Optional handler to call when a request is being rate-limited, allows you to customize the response.
	on_limit: Maybe(Rate_Limit_On_Limit),
}

Rate_Limit_Data :: struct {
	opts:       ^Rate_Limit_Opts,
	next_sweep: time.Time,
	hits:       map[net.Address]int,
	mu:         sync.Mutex,
}

// Basic rate limit based on IP address.
middleware_rate_limit :: proc(next: ^Handler, opts: ^Rate_Limit_Opts, allocator := context.allocator) -> Handler {
	assert(next != nil)

	h: Handler
	h.next = next

	data := new(Rate_Limit_Data, allocator)
	data.opts = opts
	data.hits = make(map[net.Address]int, 0, allocator)
	data.next_sweep = time.time_add(time.now(), opts.window)
	h.user_data = data

	h.handle = proc(h: ^Handler, req: ^Request, res: ^Response) {
		data := (^Rate_Limit_Data)(h.user_data)

		sync.lock(&data.mu)

		// PERF: if this is not performing, we could run a thread that sweeps on a regular basis.
		if time.since(data.next_sweep) > 0 {
			clear(&data.hits)
			data.next_sweep = time.time_add(time.now(), data.opts.window)
		}

		hits := data.hits[req.client.address]
		data.hits[req.client.address] = hits + 1
		sync.unlock(&data.mu)

		if hits > data.opts.max {
			res.status = .Too_Many_Requests

			retry_dur := int(time.diff(time.now(), data.next_sweep) / time.Second)
			buf := make([]byte, 32, context.temp_allocator)
			retry_str := strconv.itoa(buf, retry_dur)
			res.headers["retry-after"] = retry_str

			if on, ok := data.opts.on_limit.(Rate_Limit_On_Limit); ok {
				on.on_limit(req, res, on.user_data)
			}
			return
		}

		next := h.next.(^Handler)
		next.handle(next, req, res)
	}

	return h
}
