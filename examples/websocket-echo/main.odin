package ws_echo_example

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:strings"
import "core:sync"

import http "../.."
import ws   "../../websocket"

State :: struct {
	wss: ws.Server,
	s:   http.Server,
}
state: State

main :: proc() {
	context.logger = log.create_console_logger(.Debug)

	state.wss.on_message = on_message

	handler := http.handler(proc(req: ^http.Request, res: ^http.Response) {
		if err := ws.upgrade(&state.wss, req, res, nil); err != nil {
			log.infof("websocket upgrade failed: %v", err)
		}
		http.respond(res)
	})

	fmt.printf("Server stopped: %s", http.listen_and_serve(&state.s, handler))
}

on_message :: proc(s: ^ws.Server, c: ws.Connection, user: rawptr, type: ws.Message_Type, data: []byte) {
	switch type {
	case .Binary: ws.send_binary(s, c, data)
	case .Text:   ws.send_text(s, c, string(data))
	}
}
