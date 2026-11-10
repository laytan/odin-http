//+test
package mpsc

import list "core:container/intrusive/list"
import "core:testing"

// _Test_Msg is the message type used in all mpsc tests.
_Test_Msg :: struct {
	node: list.Node,
	data: int,
}

// ----------------------------------------------------------------------------
// Unit tests
// ----------------------------------------------------------------------------

@(test)
test_init :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	testing.expect(t, q.head == &q.stub, "head should point to stub after init")
	testing.expect(t, q.tail == &q.stub, "tail should point to stub after init")
	testing.expect(t, length(&q) == 0, "length should be 0 after init")
}

@(test)
test_pop_empty :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	got := pop(&q)
	testing.expect(t, got == nil, "pop on empty queue should return nil")
}

@(test)
test_push_pop_one :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	msg := _Test_Msg {
		data = 42,
	}
	msg_opt: Maybe(^_Test_Msg) = &msg
	push(&q, &msg_opt)
	testing.expect(t, length(&q) == 1, "length should be 1 after push")
	got := pop(&q)
	testing.expect(t, got != nil && got.data == 42, "pop should return the pushed message")
	testing.expect(t, length(&q) == 0, "length should be 0 after pop")
	got2 := pop(&q)
	testing.expect(t, got2 == nil, "second pop should return nil")
}

@(test)
test_fifo_order :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	a := _Test_Msg {
		data = 1,
	}
	b := _Test_Msg {
		data = 2,
	}
	c := _Test_Msg {
		data = 3,
	}
	a_opt: Maybe(^_Test_Msg) = &a
	push(&q, &a_opt)
	b_opt: Maybe(^_Test_Msg) = &b
	push(&q, &b_opt)
	c_opt: Maybe(^_Test_Msg) = &c
	push(&q, &c_opt)
	testing.expect(t, length(&q) == 3, "length should be 3 after 3 pushes")
	g1 := pop(&q)
	g2 := pop(&q)
	g3 := pop(&q)
	g4 := pop(&q)
	testing.expect(t, g1 != nil && g1.data == 1, "first pop should return 1")
	testing.expect(t, g2 != nil && g2.data == 2, "second pop should return 2")
	testing.expect(t, g3 != nil && g3.data == 3, "third pop should return 3")
	testing.expect(t, g4 == nil, "fourth pop should return nil")
	testing.expect(t, length(&q) == 0, "length zero after pop")
}

@(test)
test_push_pop_interleaved :: proc(t: ^testing.T) {
	q: Queue(_Test_Msg)
	init(&q)
	a := _Test_Msg {
		data = 10,
	}
	b := _Test_Msg {
		data = 20,
	}
	a_opt: Maybe(^_Test_Msg) = &a
	push(&q, &a_opt)
	g1 := pop(&q)
	b_opt: Maybe(^_Test_Msg) = &b
	push(&q, &b_opt)
	g2 := pop(&q)
	g3 := pop(&q)
	testing.expect(t, g1 != nil && g1.data == 10, "first interleaved pop should return 10")
	testing.expect(t, g2 != nil && g2.data == 20, "second interleaved pop should return 20")
	testing.expect(t, g3 == nil, "third interleaved pop should return nil")
}

// ----------------------------------------------------------------------------
// Example
// ----------------------------------------------------------------------------

@(private)
_example_basic_usage :: proc() -> bool {
	q: Queue(_Test_Msg)
	init(&q)
	msg := _Test_Msg {
		data = 99,
	}
	msg_opt: Maybe(^_Test_Msg) = &msg
	push(&q, &msg_opt)
	got := pop(&q)
	return got != nil && got.data == 99
}

@(test)
test_example_basic_usage :: proc(t: ^testing.T) {
	testing.expect(t, _example_basic_usage(), "basic usage example should work")
}
