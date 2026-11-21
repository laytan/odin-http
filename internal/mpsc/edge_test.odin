//+test
package mpsc

import "core:testing"
import "core:thread"

// ----------------------------------------------------------------------------
// Edge cases and stress tests
// ----------------------------------------------------------------------------

// test_stub_recycling_explicit exercises the stub-recycling path in pop.
// That path runs when exactly one item remains (head == tail, next == nil).
// Each push/pop cycle of a single item triggers it.
@(test)
test_stub_recycling_explicit :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	for i in 0 ..< 5 {
		msg := _Test_Msg {
			data = i,
		}
		msg_opt: Maybe(^_Test_Msg) = &msg
		push(&q, &msg_opt)
		got := pop(&q)
		testing.expectf(t, got != nil && got.data == i, "round %d: pop should return the pushed message", i)
		testing.expectf(t, length(&q) == 0, "round %d: length should be 0 after pop", i)
	}
}

// test_pop_exhausts_queue: push N, pop all — queue empty after.
@(test)
test_pop_exhausts_queue :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)

	N :: 50
	msgs: [N]_Test_Msg
	for i in 0 ..< N {
		msgs[i].data = i
		msg_opt: Maybe(^_Test_Msg) = &msgs[i]
		push(&q, &msg_opt)
	}

	count := 0
	for length(&q) > 0 || count < N {
		if pop(&q) != nil {
			count += 1
		}
		if length(&q) == 0 && count == N {
			break
		}
	}

	testing.expect(t, count == N, "should pop all pushed messages")
	testing.expect(t, length(&q) == 0, "length zero after full pop")
}

// _Stress_Ctx passes queue and message slice to each producer thread.
@(private)
_Stress_Ctx :: struct {
	q:    ^Queue(_Test_Msg),
	msgs: []_Test_Msg,
}

_STRESS_PRODUCERS :: 10
_STRESS_ITEMS_PER_PROD :: 1000

// test_concurrent_push_stress: _STRESS_PRODUCERS threads push _STRESS_ITEMS_PER_PROD each.
// Main thread consumes all. No messages lost; length zero after.
@(test)
test_concurrent_push_stress :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)

	total :: _STRESS_PRODUCERS * _STRESS_ITEMS_PER_PROD

	msgs := make([]_Test_Msg, total)
	defer delete(msgs)

	ctxs := make([]_Stress_Ctx, _STRESS_PRODUCERS)
	defer delete(ctxs)

	for i in 0 ..< _STRESS_PRODUCERS {
		ctxs[i] = _Stress_Ctx {
			q    = &q,
			msgs = msgs[i * _STRESS_ITEMS_PER_PROD:(i + 1) * _STRESS_ITEMS_PER_PROD],
		}
	}

	threads := make([dynamic]^thread.Thread, 0, _STRESS_PRODUCERS)
	defer delete(threads)

	for i in 0 ..< _STRESS_PRODUCERS {
		th := thread.create_and_start_with_poly_data(&ctxs[i], proc(ctx: ^_Stress_Ctx) {
			for j in 0 ..< len(ctx.msgs) {
				msg_opt: Maybe(^_Test_Msg) = &ctx.msgs[j]
				push(ctx.q, &msg_opt)
			}
		})
		append(&threads, th)
	}

	// Consume all.
	received := 0
	for received < total {
		if pop(&q) != nil {
			received += 1
		}
	}

	for th in threads {
		thread.join(th)
		thread.destroy(th)
	}

	testing.expect(t, received == total, "should receive all pushed messages")
	testing.expect(t, length(&q) == 0, "length zero after full pop")
}

// test_length_consistency: after stress, pop count and length must agree.
@(test)
test_length_consistency :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)

	N :: 200
	msgs: [N]_Test_Msg
	for i in 0 ..< N {
		msg_opt: Maybe(^_Test_Msg) = &msgs[i]
		push(&q, &msg_opt)
	}

	testing.expect(t, length(&q) == N, "length should equal number of pushes")

	count := 0
	for pop(&q) != nil {
		count += 1
	}

	testing.expect(t, count == N, "should pop exactly N messages")
	testing.expect(t, length(&q) == 0, "length zero after pop")
}
