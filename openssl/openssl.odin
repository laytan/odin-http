package openssl

import "core:c"

when ODIN_OS == .Darwin {
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
		"system:libssl.a",
		"system:libcrypto.a",
	}
}

SSL_METHOD :: struct {}
SSL_CTX :: struct {}
SSL :: struct {}

foreign lib {
	TLS_client_method :: proc() -> ^SSL_METHOD ---
	SSL_CTX_new :: proc(method: ^SSL_METHOD) -> ^SSL_CTX ---
	SSL_new :: proc(ctx: ^SSL_CTX) -> ^SSL ---
	SSL_set_fd :: proc(ssl: ^SSL, fd: c.int) -> c.int ---
	SSL_connect :: proc(ssl: ^SSL) -> c.int ---
	SSL_get_error :: proc(ssl: ^SSL, ret: c.int) -> c.int ---
	SSL_read :: proc(ssl: ^SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: ^SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_free :: proc(ssl: ^SSL) ---
	SSL_CTX_free :: proc(ctx: ^SSL_CTX) ---
}
