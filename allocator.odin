//+private
package http

import "core:container/queue"
import "core:log"
import "core:mem"

// Defaults, reassigned when server is set up.
initial_block_cap      := mem.Kilobyte * 256
max_free_blocks_queued := 64

// A lean, growing, block based allocator.
//
// The first block is kept around after a `free_all` and only free'd using `allocator_destroy`,
// so it doesn't have to allocate it each time.
//
// Blocks start at the `initial_block_cap` (configurable) size and double in size after each new block.
//
// The last allocation is saved and can be freed with `free_with_size` or resized without
// taking up a whole new region in the block.
Allocator :: struct {
	parent:     mem.Allocator,
	curr:       ^Block,
	cap:        int,
	last_alloc: rawptr,
}

Block :: struct {
	prev:       Maybe(^Block),
	size:       int,
	total_size: int,
	offset:     int,
	data:       [0]byte,
}

allocator :: proc(a: ^Allocator) -> mem.Allocator {
	return {
		procedure = allocator_proc,
		data      = a,
	}
}

allocator_init :: proc(a: ^Allocator, parent := context.allocator, loc := #caller_location) -> mem.Allocator_Error {
	a.parent = parent
	a.cap = initial_block_cap
	a.curr = allocator_new_block(a, 0, 0, loc) or_return
	return nil
}

allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                             size, alignment: int,
                             old_memory: rawptr, old_size: int,
                             loc := #caller_location) -> (bytes: []byte, err: mem.Allocator_Error) {

	a := (^Allocator)(allocator_data)
	switch mode {
	case .Alloc:
		return allocator_alloc_zerod(a, size, alignment, loc)

	case .Alloc_Non_Zeroed:
		return allocator_alloc_non_zerod(a, size, alignment, loc)

	case .Free:
		// We can only free if this was the last allocation done.
		if old_memory == a.last_alloc {
			a.curr.offset -= old_size
			a.last_alloc = nil
			return nil, nil
		}

		return nil, .Mode_Not_Implemented

	case .Free_All:
		allocator_free_all(a, loc)
		return

	case .Resize:
		// Shrink, if it was the last alloc also decrease from block offset.
		if old_size >= size {
			if a.last_alloc == old_memory {
				a.curr.offset -= old_size - size
			}

			return mem.byte_slice(old_memory, size), nil
		}

		// If this was the last alloc, and we have space in it's block, keep same spot and just
		// increase the offset.
		if a.last_alloc == old_memory {
			needed := size - old_size
			got    := a.curr.size - a.curr.offset
			if needed <= got {
				a.curr.offset += needed
				return mem.byte_slice(old_memory, size), nil
			}
		}

		// Resize with older than last allocation or doesn't fit in block, need to allocate new mem.
		bytes = allocator_alloc_non_zerod(a, size, alignment, loc) or_return
		copy(bytes, mem.byte_slice(old_memory, old_size))
		return

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free_All, .Resize, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented

	case: unreachable()
	}
}

allocator_new_block :: proc(a: ^Allocator, min_size: int, alignment: int, loc := #caller_location) -> (b: ^Block, err: mem.Allocator_Error) {
	base_offset := max(alignment, size_of(Block))
	total       := max(a.cap, min_size + base_offset)
	a.cap       *= 2

	assert_has_td(loc)
	if bucket, has_bucket := &td.free_temp_blocks[total]; has_bucket {
		if block, has_block := queue.pop_back_safe(bucket); has_block {
			b = block
			td.free_temp_blocks_count -= 1
		}
	}

	if b == nil {
		data := mem.alloc(total, max(16, align_of(Block)), a.parent, loc) or_return
		b     = (^Block)(data)
	}

	b.total_size = total
	b.size       = total - base_offset
	b.offset     = base_offset
	b.prev       = a.curr
	a.curr       = b
	return
}

allocator_alloc_zerod :: proc(a: ^Allocator, size: int, alignment: int, loc := #caller_location) -> (bytes: []byte, err: mem.Allocator_Error) {
	bytes, err = allocator_alloc_non_zerod(a, size, alignment, loc)
	mem.zero_slice(bytes)
	return
}

allocator_alloc_non_zerod :: proc(a: ^Allocator, size: int, alignment: int, loc := #caller_location) -> (bytes: []byte, err: mem.Allocator_Error) {
	if size == 0 do return

	block := a.curr
	data := ([^]byte)(&block.data)

	assert(block != nil, "you must initialize the allocator first", loc)
	assert(alignment & (alignment-1) == 0, "non-power of two alignment", loc)

	// TODO: handle int overflows.

	needed := int(mem.align_forward_uint(uint(size), uint(alignment)))
	if block.offset + needed > block.size {
		block = allocator_new_block(a, needed, alignment, loc) or_return
		data  = ([^]byte)(&block.data)
	}

	alignment_offset := 0; {
		ptr  := uintptr(data[block.offset:])
		mask := uintptr(alignment-1)
		if ptr & mask != 0 {
			alignment_offset = int(uintptr(alignment) - (ptr & mask))
		}
	}

	block.offset += alignment_offset
	bytes = data[block.offset:][:size]
	block.offset += size
	a.last_alloc = raw_data(bytes)
	return
}

allocator_free_all :: proc(a: ^Allocator, loc := #caller_location) -> (blocks: int, total_size: int, total_used: int) {
	blocks += 1
	total_size += a.curr.size + size_of(Block)
	total_used += a.curr.offset

	for a.curr.prev != nil {
		block      := a.curr
		blocks     += 1
		total_size += block.total_size
		total_used += block.offset
		a.curr      = block.prev.?
		allocator_free_block(a, block, loc)
	}

	a.curr.offset = 0
	a.cap = initial_block_cap
	return
}

allocator_destroy :: proc(a: ^Allocator, loc := #caller_location) {
	allocator_free_all(a, loc)
	allocator_free_block(a, a.curr, loc)
}

allocator_free_block :: proc(a: ^Allocator, b: ^Block, loc := #caller_location) {
	assert_has_td(loc)

	if td.free_temp_blocks_count > max_free_blocks_queued {
		free(b, a.parent)
		log.debug("max temp blocks reached, freeing the block")
		return
	}

	bucket, is_initialized := &td.free_temp_blocks[b.total_size]
	if !is_initialized {
		td.free_temp_blocks[b.total_size] = {}
		bucket = &td.free_temp_blocks[b.total_size]
		queue.init(bucket, max_free_blocks_queued, allocator=td.free_temp_blocks.allocator)
	}

	b.prev = nil
	queue.push(bucket, b)
	td.free_temp_blocks_count += 1
}

import "core:testing"

@(test)
test_allocator_alignment_boundary :: proc(t: ^testing.T) {
	arena: Allocator
	allocator_init(&arena)
	context.allocator = allocator(&arena)

	_, _ = mem.alloc(int(arena.cap)-120)
	_, err := mem.alloc(112, 32)
	testing.expect_value(t, err, nil)
}

@(test)
test_temp_allocator_big_alloc_and_alignment :: proc(t: ^testing.T) {
	arena: Allocator
	allocator_init(&arena)
	context.allocator = allocator(&arena)

	mappy: map[[8]int]int
	err := reserve(&mappy, 50000)
	testing.expect_value(t, err, nil)
}

@(test)
test_temp_allocator_returns_correct_size :: proc(t: ^testing.T) {
	arena: Allocator
	allocator_init(&arena)
	context.allocator = allocator(&arena)

	bytes, err := mem.alloc_bytes(10, 16)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(bytes), 10)
}
