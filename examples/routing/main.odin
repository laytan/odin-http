package routing_example

import "core:fmt"
import "core:log"
import "core:bytes"
import "core:encoding/json"

import http "../.."

Hello_Req_Payload :: struct {
	name: string,
}

Hello_Res_Payload :: struct {
	message: string,
}

main :: proc() {
	context.logger = log.create_console_logger()

	s: http.Server

	router: http.Router
	http.router_init(&router)

	http.route_get(&router, "/", http.handler(proc(req: ^http.Request, res: ^http.Response) {
			http.respond_html(
				res,
				`
        <html>
            <body>
                <h1>Welcome to the front page!</h1>
            </body>
        </html>`,
			)
		}))

	// Route matching is implemented using an implementation of Lua patterns, see the docs on them here:
	// https://www.lua.org/pil/20.2.html
	// They are very similar to regex patterns but a bit more limited, which makes them much easier to implement since Odin does not have a regex implementation.

	http.route_get(&router, "/hello/(%w+)", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.respond_plain(res, "Hello, ")
		bytes.buffer_write_string(&res.body, req.url_params[0])
		http.respond(res)
	}))

	// JSON/body example.
	http.route_post(&router, "/ping", http.handler(proc(req: ^http.Request, res: ^http.Response) {
		http.request_body(req, proc(body: http.Body_Type, was_alloc: bool, res: rawptr) {
			res := cast(^http.Response)res

			if err, is_err := body.(http.Body_Error); is_err {
				res.status = http.body_error_status(err)
				http.respond(res)
				return
			}

			p: Hello_Req_Payload
			if err := json.unmarshal_string(body.(http.Body_Plain) or_else "", &p); err != nil {
				log.infof("invalid ping payload %q: %s", body, err)
				res.status = http.Status.Unprocessable_Content
				return
			}

			http.respond_json(res, Hello_Res_Payload{message = fmt.tprintf("Hello %s!", p.name)})
		}, user_data = res)
	}))

	// Custom 404 page.
	http.route_all(&router, "(.*)", http.handler(proc(req: ^http.Request, res: ^http.Response) {
			http.respond_plain(
				res,
				fmt.tprintf("Welcome, could not find the path %q", req.url_params[0]),
			)
			res.status = .Not_Found
		}))

	handler := http.router_handler(&router)
	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))
}
