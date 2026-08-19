package mpsc

import "base:intrinsics"
import list "core:container/intrusive/list"

// Queue is a lock-free multi-producer, single-consumer intrusive queue.
// Based on Dmitry Vyukov’s MPSC algorithm.
// See: https://int08h.com/post/ode-to-a-vyukov-queue/
//
// "Intrusive" means the link field lives inside T, not in a separate wrapper.
// T must have exactly: node: list.Node  (no extra allocation per item).
// Do not copy Queue after init — it contains its own internal dummy node.
Queue :: struct($T: typeid) {
	head: ^list.Node, // producers only
	tail: ^list.Node, // consumer only
	stub: list.Node, // dummy node used when queue is empty
	len:  int, // atomic item count
}

// init must be called once before any push or pop.
init :: proc(q: ^Queue($T)) where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	q.stub.next = nil
	q.head = &q.stub
	q.tail = &q.stub
	q.len = 0
}

// push can be called safely from any number of threads at the same time.
// On success the passed Maybe is cleared (the queue now owns the message).
// Passing nil does nothing and returns false.
push :: proc(q: ^Queue($T), msg: ^Maybe(^T)) -> bool where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	if msg == nil || msg^ == nil {
		return false
	}

	ptr := (msg^).?
	node := &ptr.node

	intrinsics.atomic_store(&node.next, nil)
	prev := intrinsics.atomic_exchange(&q.head, node)
	intrinsics.atomic_store(&prev.next, node)
	intrinsics.atomic_add(&q.len, 1)

	msg^ = nil
	return true
}

// pop can only be called from the single consumer thread.
//
// It returns nil in two cases:
//   1. The queue is really empty.
//   2. A short "stall" — a producer has started pushing but hasn’t finished linking yet.
//
// During a stall the length may still show > 0. Just call pop again — it will succeed soon.
pop :: proc(q: ^Queue($T)) -> ^T where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	tail := q.tail
	next := intrinsics.atomic_load(&tail.next)

	if tail == &q.stub {
		if next == nil {
			return nil
		}
		q.tail = next
		tail = next
		next = intrinsics.atomic_load(&tail.next)
	}

	if next != nil {
		q.tail = next
		intrinsics.atomic_sub(&q.len, 1)
		return container_of(tail, T, "node")
	}

	// Possible stall or last item
	head := intrinsics.atomic_load(&q.head)
	if tail != head {
		return nil // stall
	}

	// Only one item left — reuse the dummy stub node
	q.stub.next = nil
	prev := intrinsics.atomic_exchange(&q.head, &q.stub)
	intrinsics.atomic_store(&prev.next, &q.stub)

	next = intrinsics.atomic_load(&tail.next)
	if next != nil {
		q.tail = next
		intrinsics.atomic_sub(&q.len, 1)
		return container_of(tail, T, "node")
	}

	return nil
}

// length returns an approximate number of items.
// It may be non-zero while pop still returns nil (during a short stall).
// Use it only for logging or heuristics.
length :: proc(q: ^Queue($T)) -> int where intrinsics.type_has_field(T, "node"),
	intrinsics.type_field_type(T, "node") == list.Node {
	return intrinsics.atomic_load(&q.len)
}
