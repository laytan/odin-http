package job

import "core:fmt"
import "core:io"
import "core:runtime"
import "core:slice"
import "core:log"

DISABLE_JOB_FORMATTER :: #config(DISABLE_JOB_FORMATTER, false)

// TODO: detect ANSI support.
_STARTED_SUFFIX   :: "\x1b[90m / started\x1b[0m"
_CANCELLED_SUFFIX :: "\x1b[90m / cancelled\x1b[0m"
_DONE_SUFFIX      :: "\x1b[90m / done\x1b[0m"
_ARROW_SUFFIX     :: " ->"

@(init, disabled=DISABLE_JOB_FORMATTER)
init_job_formatter :: proc() {
	log.debug("adding user formatter")
	if fmt._user_formatters == nil {
		fmt.set_user_formatters(new(map[typeid]fmt.User_Formatter))
	}

	fmt.register_user_formatter(Job, job_fmt)
	fmt.register_user_formatter(^Job, job_fmt)
}

// Formats a job into readable output instead of just a struct with 2 pointers it renders the full
// sequence to be understandable.
job_fmt :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
    // format normally when not using 'v' or when using hash.
    if (verb != 'v' || fi.hash) {
        fmt.fmt_struct(fi, arg, verb, type_info_of(Job).variant.(runtime.Type_Info_Struct), "Job")
        return true
    }

	job: ^Job
	is_ptr: bool
	switch &j in arg {
	case Job:
        job = &j
	case ^Job:
        job = j
		is_ptr = true
	case:
        return false
	}

    // I don't think there is a way of sequentially writing the output without an allocation.
    canvas := draw(job)
    defer {
        for row in canvas do delete(row)
        delete(canvas)
    }

    for row, i in canvas {
        if i == 0 && is_ptr {
            io.write_byte(fi.writer, '&')
        } else if i != 0 && is_ptr {
            io.write_string(fi.writer, "\n ")
        } else if i != 0 {
            io.write_string(fi.writer, "\n")
        }

        io.write_string(fi.writer, string(row))
    }

	return true
}

// Calculates the width and height needed in an output buffer to fully draw this job.
// This is a fibonacci sequence where a job needs the dimensions of its chained and batched jobs.
//
// Like a fibonacci sequence we could memoize the results,
// but I don't see jobs that will be that big being a thing.
dimensions :: proc(j: ^Job, with_spacing: bool) -> (width: int, height: int) {
	if j == nil {
		return
	}

	// if j.is_link {
	// 	return dimensions(j.batch, with_spacing)
	// }

	job_width := len(j.name) + 2
	if j.started || j.cancelled || j.done {
		if j.started {
			job_width += len(_STARTED_SUFFIX)
		}
		if j.cancelled {
			job_width += len(_CANCELLED_SUFFIX)
		}
		if j.done {
			job_width += len(_DONE_SUFFIX)
		}
	}

	if j.chain != nil {
		job_width += len(_ARROW_SUFFIX)
	}

	job_width = max(job_width, 3)

	job_height := 2 if j.batch != nil else 1

	if j.chain == nil && j.batch == nil {
		return job_width, job_height
	}

	if j.chain == nil && j.batch != nil {
		width, height = dimensions(j.batch, with_spacing)
		height += job_height
		return
	}

	if j.chain != nil && j.batch == nil {
		width, height = dimensions(j.chain, with_spacing)
		width += job_width
		return
	}

	width, height = dimensions(j.chain, with_spacing)

	mbl, mbc := dimensions(j.batch, with_spacing)

	width = width + mbl if with_spacing else max(width, mbl)
	height += mbc

	return
}

// Draws the job as a nice output based on the name and chains/batches attached.
// All arguments other than the job are optional and mostly used in the recursive nature.
draw :: proc (j: ^Job, into: [][]byte = nil, x: int = 0, y: int = 0) -> [][]byte {
	into := into

	if j == nil {
		return into
	}

	// if j.is_link {
	// 	return draw(j.batch, into, x, y)
	// }

	// Zero value useful, start of the draw.
	if into == nil {
		width, height := dimensions(j, with_spacing=true)
		into = make([][]byte, height)
		for &row in into {
			row = make([]byte, width)
			slice.fill(row, ' ')
		}
	}

	n := copy(into[y][x:], " ")
	n += copy(into[y][x+n:], j.name)

	if j.started || j.cancelled || j.done {
		if j.started {
			n += copy(into[y][x+n:], _STARTED_SUFFIX)
		}
		if j.cancelled {
			n += copy(into[y][x+n:], _CANCELLED_SUFFIX)
		}
		if j.done {
			n += copy(into[y][x+n:], _DONE_SUFFIX)
		}
	}

	if j.chain != nil {
		n += copy(into[y][x+n:], _ARROW_SUFFIX)
	}

	n += copy(into[y][x+n:], " ")

	job_width := max(n, 3)

	if j.batch != nil {
		copy(into[y+1][x+1:], " |")
	}

	job_height := 2 if j.batch != nil else 1

	if j.chain == nil && j.batch == nil {
		return into
	}

	if j.chain != nil && j.batch == nil {
		draw(j.chain, into, x + job_width, y)
		return into
	}

	if j.chain == nil && j.batch != nil {
		draw(j.batch, into, x, y + job_height)
		return into
	}

	_, chain_heigth := dimensions(j.chain, with_spacing=false)
	batch_width, _ := dimensions(j.batch, with_spacing=false)

	draw(j.chain, into, x + batch_width, y)
	draw(j.batch, into, x, y + chain_heigth)

	return into
}
