package client

import "core:mem"
import "core:fmt"
import "core:log"
import "core:io"

// TODO: MAKE MUCH BETTER AND CLEANER.

@init
init_job_formatter :: proc() {
	if fmt._user_formatters == nil {
		fmt.set_user_formatters(new(map[typeid]fmt.User_Formatter))
	}

	fmt.register_user_formatter(Job, job_fmt)
	fmt.register_user_formatter(^Job, job_fmt)
}

MAX_USER_ARGS :: 6

// Job_State :: enum {
// 	Pending,
// 	Started,
// 	Cancelled,
// 	Done,
// }

Job :: struct {
	// TODO: remove name (was for debugging)
	name:          string,

	parent:        ^Job,

	// TODO: maybe state enum?
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

// TODO: FORMAT AS A NICE TREE.
job_fmt :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	job: Job
	switch j in arg {
	case Job:  job = j
	case ^Job: job = j^
	case: return false
	}

	// if fi.hash {
	// 	delete_key(fmt._user_formatters, Job)
	// 	delete_key(fmt._user_formatters, ^Job)
	// 	fmt.fmt_arg(fi, arg, verb)
	// 	fmt.register_user_formatter(Job, job_fmt)
	// 	fmt.register_user_formatter(^Job, job_fmt)
	// 	return false
	// }

	// TODO: only do this if %v verb.

	write_job :: proc(line: io.Writer, job: Job) {
		io.write_string(line, job.name)
		io.write_rune(line, '|')

		if job.started {
			io.write_rune(line, '🎬')
		}

		if job.cancelled {
			io.write_rune(line, '❌')
		}

		if job.done {
			io.write_rune(line, '✅')
		}
		io.write_rune(line, '|')

	if job.batch != nil {
		io.write_string(line, " batches (")
		for batch := job.batch; batch != nil; batch = batch.batch {
			write_job(line, batch^)
			io.write_string(line, ",")
		}
		io.write_string(line, ")")
	}

	if job.chain != nil {
		io.write_string(line, " -> ")
		write_job(line, job.chain^)
	}

	}

	write_job(fi.writer, job)

	return true
}

/**
 * Job that will cancel the given job when called.
 */
job_cancel :: proc(to_cancel: ^Job) -> ^Job {
	cancel_job :: proc(j: ^Job, m: Handle_Mode, to_cancel: ^Job) {
		switch m {
		case .Cancel:
			done(j)

		case .Run:
			if j.cancelled do return
			cancel(to_cancel)
			done(j)
		}
	}

	return job1(to_cancel, cancel_job, "job_cancel")
}


Handle_Mode :: enum {
	Run,
	Cancel,
}

done :: proc(j: ^Job) {
	if j.done {
		log.warnf("%v already done", j)
		return
	}
	log.debugf("%v done", j)
	j.done = true

	first_of_batch := j
	for first_of_batch.parent != nil && first_of_batch.parent.batch == first_of_batch {
		first_of_batch = first_of_batch.parent
	}

	if first_of_batch.chain == nil {
		return
	}

	batch_done := true
	for batched := first_of_batch; batched != nil; batched = batched.batch {
		log.debugf("%v checking if also done", batched)
		if !batched.done {
			batch_done = false
			log.debugf("%v batch not done", batched)
			break
		}
	}

	log.debugf("%v first of batch is fully done: %v", first_of_batch, batch_done)

	if batch_done && first_of_batch.chain != nil {
		log.debugf("%v calling run after batch done", first_of_batch.chain)
		run(first_of_batch.chain)
	}
}

run :: proc(j: ^Job, loc := #caller_location) {
	log.debugf("%v run", j)
	assert(!j.started, "called run on already started job", loc)
	j.started = true

	if j.is_link {
		run(j.chain)
	} else {
		j->handle(.Run)
	}

	if j.batch != nil {
		run(j.batch)
	}
}

cancel :: proc(j: ^Job) {
	log.debugf("%v cancel", j)

	if j.cancelled || j.done do return


	if j.handle != nil {
		j.cancelled = true
		log.debugf("%v calling cancel handler", j)
		j->handle(.Cancel)
	} else {
		log.debugf("%v no cancel handler, done", j)
	}
}

cancel_full :: proc(j: ^Job, excluding: ^Job, excluding2: ^Job) {
	if j != excluding && j != excluding2 {
		cancel(j)

		if j.chain != nil {
			cancel_full(j.chain, excluding, excluding2)
		}
	}

	for jj := j; jj != nil; jj = jj.batch {
		if jj == excluding || jj == excluding2 do continue
		cancel(jj)

		if jj.chain != nil {
			cancel_full(jj.chain, excluding, excluding2)
		}
	}
}

cancel_rest :: proc(j: ^Job) {
	log.debugf("%v cancel rest", j)
	first_of_batch := j
	for first_of_batch.parent != nil && first_of_batch.parent.batch == first_of_batch {
		first_of_batch = first_of_batch.parent
	}

	cancel_full(first_of_batch, j, first_of_batch.chain)
}

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

batch :: proc(with: ^Job, j: ..^Job) -> ^Job {
	container := new(Job)
	container.is_link = true
	container.name = "batch link container"

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

	container.chain = with
	assert(with.parent == nil)
	with.parent = container
	return container
}

destroy_job :: proc(j: ^Job) {
	if j == nil do return
	destroy_job(j.batch)
	destroy_job(j.chain)
	free(j)
}

job1 :: proc(arg1: $T, handler: proc(^Job, Handle_Mode, T), name := "", loc := #caller_location) -> ^Job
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

job2 :: proc(arg1: $T, arg2: $K, handler: proc(^Job, Handle_Mode, T, K), name := "", loc := #caller_location) -> ^Job
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
