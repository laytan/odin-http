package job

import "core:mem"
import "core:log"

MAX_USER_ARGS :: 6

Job :: struct {
	name:          string,

	parent:        ^Job,

	done:          bool,
	cancelled:     bool,
	started:       bool,

	is_link:       bool,

	handle:        proc(^Job, Handle_Mode),

	user_handler:  rawptr,

	// Raw bytes of the user args, transformed back into data types before calling job handler.
	user_args:     [MAX_USER_ARGS * size_of(rawptr)]byte,

	batch:         ^Job,
	chain:         ^Job,
}

Handle_Mode :: enum {
	Run,            // Job should start performing its action and call done() after it.
	Cancel,         // Job should cancel its action and call done() after it.
}

Destroy_Mode :: enum {
	Down,           // Recursively destroy jobs batched with and chained with this job.
	Single,         // Only this job.
	Down_From_Root, // Traverses up to root, and recursively destroy each job in the data structure.
}


// Destroy (free) a job, and optionally others based on the given `destroy_mode`.
//
// NOTE: this does not delete the name of the job because those tend to be literals for debug purpose.
destroy :: proc(j: ^Job, destroy_mode: Destroy_Mode) {
	if j == nil do return

	switch destroy_mode {
	case .Single:
		free(j)
	case .Down:
		destroy(j.chain, .Down)
		destroy(j.batch, .Down)
		free(j)
	case .Down_From_Root:
		root := _root(j)
		destroy(root.chain, .Down)
		destroy(root.batch, .Down)
		free(root)
	}
}

// Start running the job chain.
run :: proc(j: ^Job) {
	assert(!j.done)
	assert(!j.started)
	assert(!j.cancelled)

	if !j.is_link {
		j.started = true
        log.debugf("%s: run", j.name)
		j->handle(.Run)
	}

	if j.batch != nil {
		run(j.batch)
	}
}

// Mark a job as done.
//
// If this job has a chain it runs it.
//
// If this job is in a batch and all other jobs in it are also done,
// it marks the batch as done and runs the batch's chain.
done :: proc(j: ^Job) {
	assert(!j.done)
	assert(!j.is_link)

	j.done = true

    log.debugf("%s: done", j.name)

	if !j.cancelled && j.chain != nil {
		run(j.chain)
	}

	first_of_batch := _first_of_batch(j)
	if first_of_batch.chain != nil && _is_batch_done(first_of_batch) {
		run(first_of_batch.chain)
	}
}

// Cancel a single job, this will make the job's run method be called and won't run it's chain.
cancel :: proc(j: ^Job) {
	if j.cancelled do return
	j.cancelled = true

	if !j.done && !j.is_link && j.started {
        log.debugf("%s: cancel", j.name)
		j->handle(.Cancel)
	}
}

// Cancels all other jobs in the job's batch.
cancel_others_in_batch :: proc(j: ^Job) {
	first_of_batch := _first_of_batch(j)

	for batch_job := first_of_batch; batch_job != nil; batch_job = batch_job.batch {
		if batch_job == j do continue
		cancel(batch_job)
		cancel_chain(batch_job.chain)
	}
}

cancel_chain :: proc(j: ^Job) {
	if j == nil do return

	cancel_chain(j.chain)

	if j.batch != nil {
		first_of_batch := _first_of_batch(j.batch)

		for batch_job := first_of_batch; batch_job != nil; batch_job = batch_job.batch {
			cancel(batch_job)
			cancel_chain(batch_job.chain)
		}
	}
}

_is_chain_done :: proc(j: ^Job) -> bool {
	if j == nil do return true

	return _is_chain_done(j.chain) && _is_batch_done(j.batch)
}

_is_batch_done :: proc(j: ^Job) -> bool {
	if j == nil do return true

	first_of_batch := _first_of_batch(j)
	assert(first_of_batch.is_link)

	batch_job := first_of_batch.batch
	for batch_job != nil {
		if !batch_job.is_link && !batch_job.done {
			return false
		}

		if !_is_chain_done(j.chain) {
			return false
		}

		batch_job = batch_job.batch
	}

	return true
}

// Traverses to the first job of this batch and returns it.
_first_of_batch :: proc(j: ^Job) -> (first_of_batch: ^Job) {
	first_of_batch = j
	for first_of_batch.parent != nil && first_of_batch.parent.batch == first_of_batch {
		first_of_batch = first_of_batch.parent
	}

	return first_of_batch
}

// Traverses up to the root of the job and returns it.
_root :: proc(j: ^Job) -> (root: ^Job) {
	for root = j; root != nil; root = root.parent {}
	return
}

// Returns a job that will cancel the given job when called.
canceller :: proc(to_cancel: ^Job, name := "canceller") -> ^Job {
	cancel_job :: proc(j: ^Job, m: Handle_Mode, to_cancel: ^Job) {
		switch m {
		case .Cancel:
			done(j)

		case .Run:
			cancel(to_cancel)
			done(j)
		}
	}

	return new1(to_cancel, cancel_job, name)
}

destroyer :: proc(to_destroy: ^Job, mode: Destroy_Mode, name := "destroyer") -> ^Job {
    destroy_job :: proc(j: ^Job, m: Handle_Mode, to_destroy: ^Job, mode: Destroy_Mode) {
        switch m {
        case .Cancel:
            done(j)
        case .Run:
            destroy(to_destroy, mode)
            done(j)
        }
    }

    return new2(to_destroy, mode, destroy_job, name)
}

// Creates a chain of the given jobs and returns the root of it.
//
// A chain runs in sequence, when the first job has `done()` called on it, it runs the next etc.
chain :: proc(first: ^Job, j: ..^Job) -> ^Job {
	edge := first
	for edge.chain != nil {
		edge = edge.chain
	}

	parent := edge
	for jj in j {
		jj.parent = parent
		parent.chain = jj
		parent = jj
	}

	return first
}

// Creates a batch of the given jobs and returns the root of it.
//
// A batch runs all jobs at the same time, when all jobs are done, it runs the next chain.
batch :: proc(with: ^Job, j: ..^Job, batch_name := "", loc := #caller_location) -> ^Job {
	container := new(Job)
	container.is_link = true
	container.name = batch_name if batch_name != "" else loc.procedure

	edge := with
	for edge.batch != nil {
		edge = edge.batch
	}

	parent := edge
	for jj in j {
		jj.parent = parent
		parent.batch = jj
		parent = jj
	}

	container.batch = with
	assert(with.parent == nil)
	with.parent = container
	return container
}

// Creates a job with 1 user argument.
new1 :: proc(arg1: $T, handler: proc(^Job, Handle_Mode, T), name := "", loc := #caller_location) -> ^Job
	where size_of(T) <= size_of(rawptr) * MAX_USER_ARGS {
	job_proc :: proc(j: ^Job, m: Handle_Mode) {
		arg1    := (^T)(&j.user_args[0])^
		handler := cast(proc(^Job, Handle_Mode, T))j.user_handler
		handler(j, m, arg1)
	}

	j := new(Job)

	j.name = name if name != "" else loc.procedure

	j.user_handler = cast(rawptr)handler
	j.handle       = job_proc

	arg1 := arg1
	copy(j.user_args[:], mem.ptr_to_bytes(&arg1))

	return j
}

// Creates a job with 2 user arguments.
new2 :: proc(arg1: $T, arg2: $K, handler: proc(^Job, Handle_Mode, T, K), name := "", loc := #caller_location) -> ^Job
	where size_of(T) + size_of(K) <= size_of(rawptr) * MAX_USER_ARGS {
	job_proc :: proc(j: ^Job, m: Handle_Mode) {
		arg1    := (^T)(&j.user_args[0])^
		arg2    := (^K)(raw_data(j.user_args[size_of(T):]))^
		handler := cast(proc(^Job, Handle_Mode, T, K))j.user_handler
		handler(j, m, arg1, arg2)
	}

	j := new(Job)

	j.name = name if name != "" else loc.procedure

	j.user_handler = cast(rawptr)handler
	j.handle       = job_proc

	arg1 := arg1
	n := copy(j.user_args[:], mem.ptr_to_bytes(&arg1))

	arg2 := arg2
	copy(j.user_args[n:], mem.ptr_to_bytes(&arg2))

	return j
}
