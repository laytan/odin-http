package http

import "core:log"

Pool :: struct {
	items: [dynamic]Pool_Entry,
	next_free: Connection_Handle,
	last_free: Connection_Handle,
}

Pool_Entry :: struct {
	item:      Connection,
	next_free: Connection_Handle,
}

Connection_Handle :: distinct int

pool_init :: proc(p: ^Pool, cap := 16, allocator := context.allocator) {
	p.items = make([dynamic]Pool_Entry, 0, cap, allocator)
	p.next_free = -1
	p.last_free = -1
}

pool_release :: proc(p: ^Pool, c: Connection_Handle) {
	// TODO: cleanup the connection.
	assert(p.items[c].next_free == -1)

	if p.last_free != -1 {
		log.debugf("appending %v to free list", c)
		p.items[p.last_free].next_free = c
		p.last_free = c
	} else {
		log.debugf("%v is first in free list", c)
		assert(p.next_free == -1)
		p.next_free = c
		p.last_free = c
	}
}

pool_get :: proc {
	pool_get_new,
	pool_get_handle,
}

pool_get_new :: proc(p: ^Pool) -> (Connection_Handle, ^Connection) {
	if p.next_free != -1 {
		log.debugf("returning %v from free list", p.next_free)
		handle := p.next_free
		item   := &p.items[handle]

		p.next_free = item.next_free
		if p.next_free == -1 {
			log.debug("free list now empty")
			p.last_free = -1
		}

		item.next_free = -1
		return handle, &item.item
	}

	assert(append_nothing(&p.items) == 1)

	handle := len(p.items)-1
	item   := &p.items[handle]

	log.debugf("returning new handle %v", handle)

	item.next_free = -1

	return Connection_Handle(handle), &item.item
}

// IMPORTANT: DO NOT STORE THIS POINTER, STORE THE HANDLE.
pool_get_handle :: proc(p: ^Pool, handle: Connection_Handle) -> ^Connection {
	return &p.items[handle].item
}

import "core:testing"
import "core:fmt"

@(test)
test_connection_pool :: proc(t: ^testing.T) {
	context.logger = log.create_console_logger()

	p: Pool
	pool_init(&p)

	h1, _ := pool_get(&p)
	testing.expect_value(t, h1, 0)
	h2, _ := pool_get(&p)
	testing.expect_value(t, h2, 1)
	pool_get(&p)
	pool_get(&p)
	pool_get(&p)

	testing.expect_value(t, p.next_free, -1)
	testing.expect_value(t, p.last_free, -1)

	pool_release(&p, h1)

	testing.expect_value(t, p.next_free, h1)
	testing.expect_value(t, p.last_free, h1)

	pool_release(&p, h2)

	testing.expect_value(t, p.next_free, h1)
	testing.expect_value(t, p.last_free, h2)
	testing.expect_value(t, p.items[p.next_free].next_free, h2)

	h6, _ := pool_get(&p)

	testing.expect_value(t, h6, h1)
	testing.expect_value(t, p.next_free, 1)
	testing.expect_value(t, p.last_free, 1)

	h7, _ := pool_get(&p)

	testing.expect_value(t, h7, h2)
	testing.expect_value(t, p.next_free, -1)
	testing.expect_value(t, p.last_free, -1)

	h8, _ := pool_get(&p)

	testing.expect_value(t, h8, 5)
	testing.expect_value(t, p.next_free, -1)
	testing.expect_value(t, p.last_free, -1)
}
