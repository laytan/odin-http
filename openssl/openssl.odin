package openssl

import "core:c"
import "core:c/libc"
import "core:log"
import "core:runtime"

// odinfmt:disable
when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
	foreign import lib {
		"./includes/darwin/libssl.a",
		"./includes/darwin/libcrypto.a",
	}
} else when ODIN_OS == .Windows {
	foreign import lib {
		"./includes/windows/libssl.lib",
		"./includes/windows/libcrypto.lib",
	}
} else {
	foreign import lib {
		"system:ssl",
		"system:crypto",
	}
}
// odinfmt:enable

Method :: struct {}
Bio :: struct {}
Bio_Method :: struct {}
Ctx :: struct {}
Ssl :: struct {}

SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55

TLSEXT_NAMETYPE_HOST_NAME :: 0

Error_Callback :: #type proc "c" (str: cstring, len: c.size_t, u: rawptr) -> c.int

foreign lib {
	@(link_name="TLS_client_method")
	method_client_tls :: proc() -> ^Method ---

	@(link_name="SSL_new")
	new :: proc(ctx: ^Ctx) -> ^Ssl ---

	@(link_name="SSL_set_fd", require_results)
	fd_set :: proc(ssl: ^Ssl, fd: c.int) -> b32 ---

	@(link_name="SSL_connect")
	_connect :: proc(ssl: ^Ssl) -> c.int ---

	@(link_name="SSL_get_error")
	_error_get :: proc(ssl: ^Ssl, ret: c.int) -> c.int ---

	@(link_name="ERR_print_errors_fp")
	errors_print_to_fp :: proc(fp: ^libc.FILE) ---

	@(link_name="ERR_print_errors_cb")
	errors_print_to_cb :: proc(cb: Error_Callback, u: rawptr) ---

	@(link_name="SSL_read")
	_read :: proc(ssl: ^Ssl, buf: [^]byte, num: c.int) -> c.int ---

	@(link_name="SSL_write")
	_write :: proc(ssl: ^Ssl, buf: [^]byte, num: c.int) -> c.int ---

	@(link_name="SSL_read_ex")
	_read_ex :: proc(ssl: ^Ssl, buf: [^]byte, num: c.int, read: ^c.int) -> b32 ---

	@(link_name="SSL_write_ex")
	_write_ex :: proc(ssl: ^Ssl, buf: [^]byte, num: c.int, written: ^c.int) -> b32 ---

	@(link_name="SSL_free")
	free :: proc(ssl: ^Ssl) ---

	@(link_name="SSL_CTX_new")
	ctx_new :: proc(method: ^Method) -> ^Ctx ---

	@(link_name="SSL_CTX_free")
	ctx_free :: proc(ctx: ^Ctx) ---

	@(link_name="SSL_ctrl")
	ctrl :: proc(ssl: ^Ssl, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---

	@(link_name="SSL_set0_rbio")
	ssl_set_rbio :: proc(ssl: ^Ssl, bio: ^Bio) ---

	@(link_name="SSL_set0_wbio")
	ssl_set_wbio :: proc(ssl: ^Ssl, bio: ^Bio) ---

	@(link_name="BIO_new")
	bio_new :: proc(method: ^Bio_Method) -> ^Bio ---

	@(link_name="BIO_get_new_index")
	bio_get_new_index :: proc() -> c.int ---

	@(link_name="BIO_meth_new")
	bio_meth_new :: proc(type: c.int, name: cstring) -> ^Bio_Method ---

	@(link_name="BIO_meth_set_write_ex")
	bio_meth_set_write_ex :: proc(meth: ^Bio_Method, write_ex: Bio_Meth_Write_Ex) ---
}

Bio_Meth_Write_Ex :: #type proc "c" (bio: ^Bio, buf: [^]byte, len: c.size_t, written: ^c.size_t) -> c.int

bio_s_nbio :: proc() -> ^Bio {
	write_ex :: proc "c" (bio: ^Bio, buf: [^]byte, len: c.size_t, written: ^c.size_t) -> c.int {
		context = runtime.default_context()
		unimplemented()
	}

	m := bio_meth_new(bio_get_new_index(), "nbio")
	bio_meth_set_write_ex(m, write_ex)
	return bio_new(m)
}

@(require_results)
read :: proc(ssl: ^Ssl, buf: []byte) -> (n: c.int, ok: bool) {
	l := len(buf)
	if l <= 0 {
		ok = true
		return
	}

	// If there is more space than max(i32) in the slice we need multiple calls.
	l = min(l, int(max(c.int)))

	ok = bool(_read_ex(ssl, raw_data(buf), c.int(l), &n))
	return
}

@(require_results)
read_full :: proc(ssl: ^Ssl, buf: []byte) -> (n: int, ok: bool) {
	l := len(buf)
	for n < l {
		_n := read(ssl, buf[n:]) or_return
		n  += int(_n)
	}

	ok = n == l
	return
}

@(require_results)
write :: proc(ssl: ^Ssl, buf: []byte) -> (n: c.int, ok: bool) {
	l := len(buf)
	if l <= 0 {
		ok = true
		return
	}

	// If there is more than max(i32) in the slice we need multiple calls.
	l = min(l, int(max(c.int)))

	ok = bool(_write_ex(ssl, raw_data(buf), c.int(l), &n))
	return
}

@(require_results)
write_full :: proc(ssl: ^Ssl, buf: []byte) -> (n: int, ok: bool) {
	l := len(buf)
	for n < l {
		_n := write(ssl, buf[n:]) or_return
		n  += int(_n)
	}

	ok = n == l
	return
}

@(require_results)
connect :: proc(ssl: ^Ssl) -> (fatal: bool, err: Error) {
	ret := _connect(ssl)
	switch {
	case ret == 1:
		// no-op.
	case ret == 2:
		err = error_get(ssl, ret)
	case:
		fatal = true
		err = error_get(ssl, ret)
	}
	return
}

// This is a macro in c land (SSL_set_tlsext_host_name).
@(require_results)
tlsext_hostname_set :: #force_inline proc(ssl: ^Ssl, name: cstring) -> bool {
	return ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_HOST_NAME, rawptr(name)) == 1
}

Error :: enum {
	None,
	Ssl,
	Want_Read,
	Want_Write,
	Want_X509_Lookup,
	Syscall,
	Zero_Return,
	Want_Connect,
	Want_Accept,
	Want_Async,
	Want_Async_Job,
	Want_Client_Hello_CB,
}

error_get :: proc(ssl: ^Ssl, ret: c.int) -> Error {
	return Error(_error_get(ssl, ret))
}

errors_print :: proc {
	errors_print_to_fp,
	errors_print_to_stderr,
	errors_print_to_cb,
	errors_print_to_log,
}

errors_print_to_stderr :: #force_inline proc() { errors_print(libc.stderr) }

errors_print_to_log :: proc(logger: ^runtime.Logger) {
	errors_print_to_cb(proc "c" (str: cstring, len: c.size_t, u: rawptr) -> c.int {
		context = runtime.default_context()
		context.logger = (cast(^runtime.Logger)u)^

		log.error(string((cast([^]byte)str)[:len]))
		return 0
	}, logger)
}
