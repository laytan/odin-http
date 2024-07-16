package openssl

import "core:c"
import "core:net"
import "core:c/libc"

import http ".."

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
	SSL_get_error :: proc(ssl: ^SSL, ret: c.int) -> Error ---
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

Error :: enum c.int {
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

http_client_ssl_implementation :: proc() -> http.Client_SSL {
	return {
		implemented = true,
		client_create = proc() -> http.SSL_Client {
			method := TLS_client_method()
			assert(method != nil)
			ctx := SSL_CTX_new(method)
			assert(ctx != nil)
			return http.SSL_Client(ctx)
		},
		client_destroy = proc(c: http.SSL_Client) {
			SSL_CTX_free((^SSL_CTX)(c))
		},
		connection_create = proc(c: http.SSL_Client, socket: net.TCP_Socket, host: cstring) -> http.SSL_Connection {
			conn := SSL_new((^SSL_CTX)(c))
			assert(conn != nil)
			ret: i32
			ret = SSL_set_tlsext_host_name(conn, host)
			assert(ret == 1)
			ret = SSL_set_fd(conn, i32(socket))
			assert(ret == 1)
			return http.SSL_Connection(conn)
		},
		connection_destroy = proc(c: http.SSL_Client, conn: http.SSL_Connection) {
			SSL_free((^SSL)(conn))
		},
		connect = proc(c: http.SSL_Connection) -> http.SSL_Result {
			ssl := (^SSL)(c)
			switch ret := SSL_connect(ssl); ret {
			case 1:
				return nil
			case 0:
				return .Shutdown
			case:
				assert(ret < 0)
				#partial switch SSL_get_error(ssl, ret) {
				case .Want_Read:  return .Want_Read
				case .Want_Write: return .Want_Write
				case:             return .Fatal
				}
			}
		},
		send = proc(c: http.SSL_Connection, buf: []byte) -> (int, http.SSL_Result) {
			ssl := (^SSL)(c)
			assert(len(buf) > 0)
			assert(len(buf) <= int(max(i32)))
			switch ret := SSL_write(ssl, raw_data(buf), i32(len(buf))); {
			case ret > 0:
				assert(int(ret) == len(buf))
				return int(ret), nil
			case:
				#partial switch SSL_get_error(ssl, ret) {
				case .Want_Read:   return 0, .Want_Read
				case .Want_Write:  return 0, .Want_Write
				case .Zero_Return: return 0, .Shutdown
				case:              return 0, .Fatal
				}
			}
		},
		recv = proc(c: http.SSL_Connection, buf: []byte) -> (int, http.SSL_Result) {
			ssl := (^SSL)(c)
			assert(len(buf) > 0)
			assert(len(buf) <= int(max(i32)))
			switch ret := SSL_read(ssl, raw_data(buf), i32(len(buf))); {
			case ret > 0:
				return int(ret), nil
			case:
				#partial switch SSL_get_error(ssl, ret) {
				case .Want_Read:   return 0, .Want_Read
				case .Want_Write:  return 0, .Want_Write
				case .Zero_Return: return 0, .Shutdown
				case:              return 0, .Fatal
				}
			}
		},
	}
}

