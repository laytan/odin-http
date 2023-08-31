package empty_ok_all

import "core:fmt"

import http "../../.."

main :: proc() {
	s: http.Server

	fmt.println("Listening on http://localost:8080...")

	http.listen_and_serve(
		&s,
		http.handler(proc(_: ^http.Request, res: ^http.Response) {
			res.status = .OK
			http.respond(res)
		}),
	)
}
