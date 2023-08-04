package nbio

import "core:mem"
import "core:container/queue"
import "core:log"

Pool :: struct($T: typeid) {
	allocator: mem.Allocator,
	objects: queue.Queue(^T),
}

DEFAULT_STARTING_CAP :: 8

pool_init :: proc(p: ^Pool($T), cap := DEFAULT_STARTING_CAP, allocator := context.allocator) {
	p.allocator = allocator
	queue.init(&p.objects, cap, allocator)
	for _ in 0..<cap {
		queue.push_back(&p.objects, new(T, allocator))
	}
}

pool_destroy :: proc(p: ^Pool($T)) {
	for obj in queue.pop_front_safe(&p.objects) {
		free(obj, p.allocator)
	}

	queue.destroy(&p.objects)
}

pool_get :: proc(p: ^Pool($T)) -> ^T {
	elem, ok := queue.pop_front_safe(&p.objects)
	if !ok {
		log.debug("allocating new object for object pool")
		return new(T, p.allocator)
	}

	log.debug("returning existing object for object pool, length: ", queue.len(p.objects))
	return elem
}

pool_put :: proc(p: ^Pool($T), elem: ^T) {
	queue.push_back(&p.objects, elem)
}
