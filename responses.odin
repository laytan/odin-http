package http

import "core:bytes"
import "core:encoding/json"
import "core:io"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:log"

import "nbio"

// Sets the response to one that sends the given HTML.
respond_html :: proc(r: ^Response, html: string, send := true) {
	defer if send do respond(r)

	r.status = .OK
	bytes.buffer_write_string(&r.body, html)
	r.headers["content-type"] = mime_to_content_type(Mime_Type.Html)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(r: ^Response, text: string, send := true) {
	defer if send do respond(r)

	r.status = .OK
	bytes.buffer_write_string(&r.body, text)
	r.headers["content-type"] = mime_to_content_type(Mime_Type.Plain)
}

/*
Sends the content of the file at the given path as the response.

This procedure uses non blocking IO and only allocates the size of the file in the body's buffer,
no other allocations or temporary buffers, this is to make it as fast as possible.

The content type is taken from the path, optionally overwritten using the parameter.

If the file doesn't exist, a 404 response is sent.
If any other error occurs, a 500 is sent and the error is logged.

// PERF: we are still putting the content into the Response.body buffer, and the respond call
// is then creating a new buffer, writing headers etc. and copying this buffer into it, so there
// are still inefficiencies.
*/
respond_file :: proc(r: ^Response, path: string, content_type: Maybe(Mime_Type) = nil, loc := #caller_location) {
	assert_has_td(loc)
	io := &td.io
	handle, errno := nbio.open(io, path)
	if errno != os.ERROR_NONE {
		if errno == os.ENOENT {
			log.debugf("respond_file, open %q, no such file or directory", path)
		} else {
			log.warnf("respond_file, open %q error: %i", path, errno)
		}

		respond(r, Status.Not_Found)
		return
	}

	size, err := nbio.seek(io, handle, 0, .End)
	if err != os.ERROR_NONE {
		log.errorf("Could not seek the file size of file at %q, error number: %i", path, err)
		respond(r, Status.Internal_Server_Error)
		nbio.close(io, handle, nil, proc(_: rawptr, _: bool) {})
		return
	}

	_, err = nbio.seek(io, handle, 0, .Set)
	if err != os.ERROR_NONE {
		log.errorf("Could not seek back to the start of file at %q, error number: %i", path, err)
		respond(r, Status.Internal_Server_Error)
		nbio.close(io, handle, nil, proc(_: rawptr, _: bool) {})
		return
	}

	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)
	r.headers["content-type"] = content_type

	bytes.buffer_grow(&r.body, size)
	buf := _dynamic_unwritten(r.body.buf)

	on_read :: proc(user: rawptr, read: int, err: os.Errno) {
		r := cast(^Response)user
		io := &td.io
		handle := os.Handle(uintptr(context.user_ptr))

		// Update the size and whats left to read.
		_dynamic_add_len(&r.body.buf, read)
		context.user_index -= read

		if err != os.ERROR_NONE {
			log.errorf("Reading file from respond_file failed, error number: %i", err)
			respond(r, Status.Internal_Server_Error)
			nbio.close(io, handle, nil, proc(_: rawptr, _: bool) {})
			return
		}

		// There is more to read.
		if context.user_index > 0 {
			log.debug("respond_file did not read the whole file at once, requires more reading")

			buf := _dynamic_unwritten(r.body.buf)
			nbio.read(io, handle, buf, r, on_read)
			return
		}

		respond(r, Status.OK)
		nbio.close(io, handle, nil, proc(_: rawptr, _: bool) {})
	}

	// Using the context.user_index for the amount of bytes that are left to be read.
	context.user_index = size
	// Using the context.user_ptr to point to the file handle.
	context.user_ptr   = rawptr(uintptr(handle))

	nbio.read(io, handle, buf, r, on_read)
}

/*
Responds with the given content, determining content type from the given path.

This is very useful when you want to `#load(path)` at compile time and respond with that.
*/
respond_file_content :: proc(r: ^Response, path: string, content: []byte, send := true) {
	defer if send do respond(r)

	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)

	r.status = .OK
	r.headers["content-type"] = content_type
	bytes.buffer_write(&r.body, content)
}

// Sets the response to one that, based on the request path, returns a file.
// base:    The base of the request path that should be removed when retrieving the file.
// target:  The path to the directory to serve.
// request: The request path.
//
// Path traversal is detected and cleaned up.
// The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
respond_dir :: proc(r: ^Response, base, target, request: string, send := true) {
	if !strings.has_prefix(request, base) {
		respond(r, Status.Not_Found)
		return
	}

	// Detect path traversal attacks.
	req_clean := filepath.clean(request, context.temp_allocator)
	base_clean := filepath.clean(base, context.temp_allocator)
	if !strings.has_prefix(req_clean, base_clean) {
		respond(r, Status.Not_Found)
		return
	}

	file_path := filepath.join([]string{"./", target, strings.trim_prefix(req_clean, base_clean)}, context.temp_allocator)
	respond_file(r, file_path)
}

// Sets the response to one that returns the JSON representation of the given value.
respond_json :: proc(r: ^Response, v: any, opt: json.Marshal_Options = {}, send := true) -> json.Marshal_Error {
	defer if send do respond(r)

	stream := bytes.buffer_to_stream(&r.body)
	opt := opt
	if err := json.marshal_to_writer(io.to_writer(stream), v, &opt); err != nil {
		r.status = .Internal_Server_Error
		return err
	}

	r.status = .OK
	r.headers["content-type"] = mime_to_content_type(Mime_Type.Json)

	return nil
}

respond_with_none :: proc(r: ^Response, loc := #caller_location) {
	assert_has_td(loc)

	conn := r._conn
	req := conn.loop.req

	// Respond as head request if we set it to get.
	if rline, ok := req.line.(Requestline); ok && req.is_head && conn.server.opts.redirect_head_to_get {
		rline.method = .Head
	}

	response_send(r, conn)
}

respond_with_status :: proc(r: ^Response, status: Status) {
	r.status = status
	respond(r)
}

respond_with_content_type :: proc(r: ^Response, content_type: Mime_Type) {
	r.headers["content-type"] = mime_to_content_type(content_type)
	respond(r)
}

respond_with_status_and_content_type :: proc(r: ^Response, status: Status, content_type: Mime_Type) {
	r.status = status
	r.headers["content-type"] = mime_to_content_type(content_type)
	respond(r)
}

// Sends the response back to the client, handlers should call this.
respond :: proc {
	respond_with_none,
	respond_with_status,
	respond_with_content_type,
	respond_with_status_and_content_type,
}
