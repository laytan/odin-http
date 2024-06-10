package ws_chatroom_example

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:log"
import "core:strings"
import "core:sync"

import http "../.."
import ws   "../../websocket"

State :: struct {
	wss:         ws.Server,
	messages:    [dynamic]string,
	messages_mu: sync.RW_Mutex,
}
state: State

main :: proc() {
	context.logger = log.create_console_logger(.Debug)

	state.wss = {
		on_open    = chat_open,
		on_message = chat_message,
	}

	s: http.Server

	router: http.Router
	http.router_init(&router)

	http.route_get(&router, "/chat", http.handler(chat))

	handler := http.router_handler(&router)

	fmt.printf("Server stopped: %s", http.listen_and_serve(&s, handler))
}

chat :: proc(req: ^http.Request, res: ^http.Response) {
	if err := ws.upgrade(&state.wss, req, res, nil); err != nil {
		log.infof("websocket upgrade handshake failed: %v", err)
	}
	http.respond(res)
}

// Send all current messages to new users.
chat_open :: proc(s: ^ws.Server, c: ws.Connection, user: rawptr) {
	ws_stream: ws.Stream
	stream := ws.init_stream(&ws_stream, s, c)
	defer io.flush(stream)

	sync.shared_guard(&state.messages_mu)
	json.marshal_to_writer(stream, &state.messages, &{})
}

// When a message is received, broadcast it to everybody.
chat_message :: proc(s: ^ws.Server, c: ws.Connection, user: rawptr, type: ws.Message_Type, data: []byte) {
	message := strings.clone(string(data))
	{
		sync.guard(&state.messages_mu)
		append(&state.messages, message)
	}

	i: int
	for other in ws.connections_iter(s, &i) {
		ws.send_text(s, other, message)
	}
}
