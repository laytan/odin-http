package nbio

import "core:mem"
import "core:mem/virtual"
import "core:container/queue"

// An object pool where the objects are allocated on a growing arena.
Pool :: struct($T: typeid) {
	allocator:         mem.Allocator,
	arena:             virtual.Arena,
	objects_allocator: mem.Allocator,
	objects:           queue.Queue(^T),
}

DEFAULT_STARTING_CAP :: 8

pool_init :: proc(p: ^Pool($T), cap := DEFAULT_STARTING_CAP, allocator := context.allocator) -> mem.Allocator_Error {
	virtual.arena_init_growing(&p.arena) or_return
	p.objects_allocator = virtual.arena_allocator(&p.arena)

	p.allocator = allocator
	queue.init(&p.objects, cap, allocator) or_return
	for _ in 0 ..< cap {
		_ = queue.push_back(&p.objects, new(T, p.objects_allocator)) or_return
	}

	return nil
}

pool_destroy :: proc(p: ^Pool($T)) {
	virtual.arena_destroy(&p.arena)
	queue.destroy(&p.objects)
}

pool_get :: proc(p: ^Pool($T)) -> (^T, mem.Allocator_Error) #optional_allocator_error {
	elem, ok := queue.pop_front_safe(&p.objects)
	if !ok {
		return new(T, p.objects_allocator)
	}

	return elem, nil
}

pool_put :: proc(p: ^Pool($T), elem: ^T) -> mem.Allocator_Error {
	_, err := queue.push_back(&p.objects, elem)
	return err
}
