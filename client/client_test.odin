package client

import "core:testing"

import openssl "../openssl"

@(test)
test_request_transport_destroy :: proc(t: ^testing.T) {
	ctx := openssl.SSL_CTX_new(openssl.TLS_client_method())
	testing.expect(t, ctx != nil)
	if ctx == nil {
		return
	}

	ssl := openssl.SSL_new(ctx)
	testing.expect(t, ssl != nil)
	if ssl == nil {
		openssl.SSL_CTX_free(ctx)
		return
	}

	transport := Request_Transport{ssl = ssl, ctx = ctx}
	request_transport_destroy(&transport)
	testing.expect(t, transport.ssl == nil)
	testing.expect(t, transport.ctx == nil)
	testing.expect(t, transport.socket == nil)

	// Error cleanup is safe to call again after ownership has been cleared.
	request_transport_destroy(&transport)
}
