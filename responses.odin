package http

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Sets the response to one that sends the given HTML.
respond_html :: proc(using r: ^Response, html: string, send := true) {
	defer if send do respond(r)

	status = .Ok
	bytes.buffer_write_string(&body, html)
	headers["content-type"] = mime_to_content_type(Mime_Type.Html)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(using r: ^Response, text: string, send := true) {
	defer if send do respond(r)

	status = .Ok
	bytes.buffer_write_string(&body, text)
	headers["content-type"] = mime_to_content_type(Mime_Type.Plain)
}

// Sets the response to one that sends the contents of the file at the given path.
// Content-Type header is set based on the file extension, see the MimeType enum for known file extensions.
respond_file :: proc(using r: ^Response, path: string, send := true, allocator := context.temp_allocator) {
	defer if send do respond(r)

	bs, ok := os.read_entire_file(path, allocator)
	if !ok {
		status = .NotFound
		return
	}

	respond_file_content(r, path, bs)
}

respond_file_content :: proc(using r: ^Response, path: string, content: []byte, send := true) {
	defer if send do respond(r)

	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)

	status = .Ok
	headers["content-type"] = content_type
	bytes.buffer_write(&body, content)
}

// Sets the response to one that, based on the request path, returns a file.
// base:    The base of the request path that should be removed when retrieving the file.
// target:  The path to the directory to serve.
// request: The request path.
//
// Path traversal is detected and cleaned up.
// The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
respond_dir :: proc(using r: ^Response, base, target, request: string, send := true, allocator := context.temp_allocator) {
	defer if send do respond(r)

	if !strings.has_prefix(request, base) {
		status = .NotFound
		return
	}

	// Detect path traversal attacks.
	req_clean := filepath.clean(request, allocator)
	base_clean := filepath.clean(base, allocator)
	if !strings.has_prefix(req_clean, base_clean) {
		status = .NotFound
		return
	}

	file_path := filepath.join([]string{"./", target, strings.trim_prefix(req_clean, base_clean)}, allocator)
	respond_file(r, file_path)
}

// Sets the response to one that returns the JSON representation of the given value.
respond_json :: proc(using r: ^Response, v: any, opt: json.Marshal_Options = {}, send := true) -> json.Marshal_Error {
	defer if send do respond(r)

	stream := bytes.buffer_to_stream(&r.body)
	opt := opt
	if err := json.marshal_to_writer(io.to_writer(stream), v, &opt); err != nil {
		status = .Internal_Server_Error
		return err
	}

	status = .Ok
	headers["content-type"] = mime_to_content_type(Mime_Type.Json)

	return nil
}

