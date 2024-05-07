package openssl

import "base:runtime"
import "core:c"
import "core:log"
import "core:c/libc"

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

SSL_METHOD :: struct {}
SSL_CTX :: struct {}
SSL :: struct {}

SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55

TLSEXT_NAMETYPE_host_name :: 0

Error_Callback :: #type proc "c" (str: cstring, len: c.size_t, u: rawptr) -> c.int

foreign lib {
	TLS_client_method :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_set_fd :: proc(ssl: ^SSL, fd: c.int) -> c.int ---
	SSL_connect :: proc(ssl: ^SSL) -> c.int ---
	SSL_get_error :: proc(ssl: ^SSL, ret: c.int) -> c.int ---
	ERR_print_errors_fp :: proc(fp: ^libc.FILE) ---
	ERR_print_errors_cb :: proc(cb: Error_Callback, u: rawptr) ---
	SSL_read :: proc(ssl: ^SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: ^SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_free :: proc(ssl: ^SSL) ---
	SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
	SSL_ctrl :: proc(ssl: ^SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
}

// This is a macro in c land.
SSL_set_tlsext_host_name :: proc(ssl: ^SSL, name: cstring) -> c.int {
	return c.int(SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name)))
}

ERR_print_errors :: proc {
	ERR_print_errors_fp,
	ERR_print_errors_stderr,
}

ERR_print_errors_stderr :: proc() {
	ERR_print_errors_fp(libc.stderr)
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

error_get :: proc(ssl: ^SSL, ret: c.int) -> Error {
	return Error(SSL_get_error(ssl, ret))
}

errors_print :: proc {
	ERR_print_errors_fp,
	errors_print_to_stderr,
	ERR_print_errors_cb,
	errors_print_to_log,
}

errors_print_to_stderr :: #force_inline proc() { errors_print(libc.stderr) }

errors_print_to_log :: proc(logger: ^runtime.Logger) {
	ERR_print_errors_cb(proc "c" (str: cstring, len: c.size_t, u: rawptr) -> c.int {
		context = runtime.default_context()
		context.logger = (cast(^runtime.Logger)u)^

		log.error(string((cast([^]byte)str)[:len]))
		return 0
	}, logger)
}
