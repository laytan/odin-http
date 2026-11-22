package body_size_error

import "core:bufio"
import "core:encoding/json"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:slice"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import http "../.."

Request_Case :: struct {
	name:   string,
	wire:   string,
	status: http.Status,
	body:   string,
}

Client_State :: struct {
	t:        ^testing.T,
	server:   ^http.Server,
	endpoint: net.Endpoint,
	cases:    []Request_Case,
}

@(test)
body_limit_keeps_size_facts_and_scanner_causes :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)
	event_loop_error := nbio.acquire_thread_event_loop()
	if !testing.expectf(t, event_loop_error == nil, "event loop initialization: %v", event_loop_error) { return }
	defer nbio.release_thread_event_loop()

	// The scanner checks its ceiling when a doubled buffer is full, after the request headers.
	oversized_line := strings.repeat("x", 2 * bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE)
	defer delete(oversized_line)
	scanner_wire := fmt.aprintf("Transfer-Encoding: chunked\r\n\r\n1;%s\r\nx\r\n0\r\n\r\n", oversized_line)
	defer delete(scanner_wire)

	cases := []Request_Case{
		{
			name = "fixed body at the limit",
			wire = "Content-Length: 4\r\n\r\nabcd",
			status = .OK,
			body = "abcd",
		},
		{
			name = "fixed size rejected before payload",
			wire = "Content-Length: 5\r\n\r\n",
			status = .Payload_Too_Large,
			body = `{"max_length":4,"consumed_length":0,"next_length":5,"framing":"Content_Length"}`,
		},
		{
			name = "chunked body at the limit",
			wire = "Transfer-Encoding: chunked\r\n\r\n2\r\nab\r\n2\r\ncd\r\n0\r\n\r\n",
			status = .OK,
			body = "abcd",
		},
		{
			name = "first chunk rejected before payload",
			wire = "Transfer-Encoding: chunked\r\n\r\n5\r\n",
			status = .Payload_Too_Large,
			body = `{"max_length":4,"consumed_length":0,"next_length":5,"framing":"Chunked"}`,
		},
		{
			name = "ordinary chunked body keeps consumed payload length",
			wire = "Transfer-Encoding: chunked\r\n\r\n2\r\nab\r\n3\r\ncde\r\n0\r\n\r\n",
			status = .Payload_Too_Large,
			body = `{"max_length":4,"consumed_length":2,"next_length":3,"framing":"Chunked"}`,
		},
		{
			name = "malformed content length",
			wire = "Content-Length: invalid\r\n\r\n",
			status = .Bad_Request,
			body = `"Bad_Read_Count"`,
		},
		{
			name = "malformed chunk size",
			wire = "Transfer-Encoding: chunked\r\n\r\ninvalid\r\n",
			status = .Bad_Request,
			body = `"Bad_Read_Count"`,
		},
		{
			name = "negative chunk size",
			wire = "Transfer-Encoding: chunked\r\n\r\n-1\r\n",
			status = .Bad_Request,
			body = `"Bad_Read_Count"`,
		},
		{
			name = "scanner token ceiling keeps its original error",
			wire = scanner_wire,
			status = .Payload_Too_Large,
			body = `"Too_Long"`,
		},
		{
			name = "scanner end of stream keeps its original error",
			wire = "Content-Length: 2\r\n\r\n",
			status = .Bad_Request,
			body = `"EOF"`,
		},
		{
			name = "negative content length",
			wire = "Content-Length: -1\r\n\r\n",
			status = .Bad_Request,
			body = `"Bad_Read_Count"`,
		},
	}

	server := http.Server{}
	options := http.Default_Server_Opts
	options.thread_count = 1
	listen_error := http.listen(&server, {address = net.IP4_Loopback, port = 0}, options)
	if !testing.expect_value(t, listen_error, nil) { return }
	endpoint, endpoint_error := net.bound_endpoint(server.tcp_sock)
	if !testing.expect_value(t, endpoint_error, nil) { return }

	client := Client_State{t = t, server = &server, endpoint = endpoint, cases = cases}
	client_thread := thread.create_and_start_with_poly_data(&client, send_requests, context)
	defer thread.destroy(client_thread)
	defer thread.join(client_thread)

	serve_error := http.serve(&server, http.handler(read_body))
	testing.expect_value(t, serve_error, nil)
}

@(private)
read_body :: proc(request: ^http.Request, response: ^http.Response) {
	http.body(request, 4, response, proc(user_data: rawptr, body: http.Body, body_error: http.Body_Error) {
		response := cast(^http.Response)user_data
		if body_error == nil {
			http.respond_plain(response, body)
			return
		}

		encoded, marshal_error := json.marshal(body_error, {use_enum_names = true}, context.temp_allocator)
		assert(marshal_error == nil)
		http.respond_plain(response, string(encoded), http.body_error_status(body_error))
	})
}

@(private)
send_requests :: proc(client: ^Client_State) {
	defer http.server_shutdown(client.server)
	for request_case in client.cases {
		check_request(client, request_case)
	}
}

@(private)
check_request :: proc(client: ^Client_State, request_case: Request_Case) {
	socket, dial_error := net.dial_tcp(client.endpoint)
	if !testing.expectf(client.t, dial_error == nil, "%s: dial: %v", request_case.name, dial_error) { return }
	defer net.close(socket)
	if !testing.expect_value(client.t, net.set_option(socket, .Receive_Timeout, 2 * time.Second), nil) { return }
	if !testing.expect_value(client.t, net.set_option(socket, .Send_Timeout, 2 * time.Second), nil) { return }

	wire := fmt.aprintf("POST / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n%s", request_case.wire)
	defer delete(wire)
	sent, send_error := net.send(socket, slice.from_ptr(raw_data(wire), len(wire)))
	if !testing.expectf(client.t, send_error == nil && sent == len(wire), "%s: sent %d/%d: %v", request_case.name, sent, len(wire), send_error) { return }
	if !testing.expect_value(client.t, net.shutdown(socket, .Send), nil) { return }

	response := strings.builder_make()
	defer strings.builder_destroy(&response)
	buffer := make([]u8, 1024)
	defer delete(buffer)
	for {
		received, receive_error := net.recv(socket, buffer)
		strings.write_bytes(&response, buffer[:received])
		if receive_error == .Connection_Closed { break }
		if !testing.expectf(client.t, receive_error == nil, "%s: receive: %v", request_case.name, receive_error) { return }
		if received == 0 { break }
	}

	wire_response := strings.to_string(response)
	status_line := fmt.tprintf("HTTP/1.1 %d ", request_case.status)
	testing.expectf(client.t, strings.has_prefix(wire_response, status_line), "%s: expected %s, received %s", request_case.name, status_line, wire_response)
	separator := strings.index(wire_response, "\r\n\r\n")
	if !testing.expectf(client.t, separator >= 0, "%s: missing response headers: %s", request_case.name, wire_response) { return }
	testing.expectf(client.t, wire_response[separator + 4:] == request_case.body, "%s: expected %s, received %s", request_case.name, request_case.body, wire_response[separator + 4:])
}
