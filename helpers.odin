//+private
package http

@(require)
import "base:runtime"

import "core:io"

// NOTE: `to` is assumed lowercase!
@(private)
ascii_case_insensitive_eq :: proc(cmp: string, to: string) -> bool {
	if cmp == to           { return true  }
	if len(cmp) != len(to) { return false }

	to := to
	for c, i in transmute([]byte)cmp {
		switch c {
		case 'A'..='Z':
			DIFF :: 'a' - 'A'
			if c + DIFF != to[i] { return false }
		case:
			if c != to[i] { return false }
		}
	}

	return true
}

@(private)
dynamic_unwritten :: proc(d: [dynamic]$E) -> []E  {
	return (cast([^]E)raw_data(d))[len(d):cap(d)]
}

@(private)
dynamic_add_len :: proc(d: ^[dynamic]$E, len: int) {
	(transmute(^runtime.Raw_Dynamic_Array)d).len += len
}

@(private)
write_padded_int :: proc(w: io.Writer, i: int) -> io.Error {
	if i < 10 {
		io.write_string(w, PADDED_NUMS[i]) or_return
		return nil
	}

	_, err := io.write_int(w, i)
	return err
}

@(private)
write_escaped_newlines :: proc(w: io.Writer, v: string) -> io.Error {
	for c in v {
		if c == '\n' {
			io.write_string(w, "\\n") or_return
		} else {
			io.write_rune(w, c) or_return
		}
	}
	return nil
}

@(private)
PADDED_NUMS := [10]string{"00", "01", "02", "03", "04", "05", "06", "07", "08", "09"}

@(private)
DAYS := [7]string{"Sun, ", "Mon, ", "Tue, ", "Wed, ", "Thu, ", "Fri, ", "Sat, "}

@(private)
MONTHS := [13]string {
	" ", // Jan is 1, so 0 should never be accessed.
	" Jan ",
	" Feb ",
	" Mar ",
	" Apr ",
	" May ",
	" Jun ",
	" Jul ",
	" Aug ",
	" Sep ",
	" Oct ",
	" Nov ",
	" Dec ",
}
