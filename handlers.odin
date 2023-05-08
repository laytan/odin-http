package http

import "core:time"
import "core:log"

Handler :: struct {
	data:   rawptr,
	next:   Maybe(^Handler),
	handle: proc(^Handler, ^Request, ^Response),
}

handler_proc :: proc(handle: proc(^Request, ^Response)) -> Handler {
	h: Handler
	h.data = rawptr(handle)

	handle := proc(h: ^Handler, req: ^Request, res: ^Response) {
		p := (proc(^Request, ^Response))(h.data)
		p(req, res)
	}

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
	h.data = opts != nil ? opts : &Default_Logger_Opts
	h.next = next

	handle := proc(h: ^Handler, req: ^Request, res: ^Response) {
		opts := (^Logger_Opts)(h.data)
		rline := req.line.(Requestline)

		start: time.Tick
		if opts.log_time do start = time.tick_now();

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
			case:          log.warn("middleware_logger does not have a next handler")
		}
	}

	h.handle = handle
	return h
}
