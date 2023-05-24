// package patterns is an implementation of the patterns syntax also found in Lua.
// They are a lot like regex but have some limitations and advantages.
// See the Lua documentation pages for in depth coverage and examples here:
// https://www.lua.org/pil/20.2.html
package pattern

import "core:mem"
import "core:strings"
import "core:bytes"
import "core:log"

// Find matches the pattern against source.
//
// Captures are slices into the source string.
//
// src[start:end] is the full matched part of src.
//
// The captures array is allocated using the given allocator, there is also
// some state allocated while matching which is freed at the end.
find :: proc(src, pattern: string, allocator := context.allocator) -> (
	ok: bool,           // Did it match?
	start: int,         // Where the match starts.
	end: int,           // Where the match ends.
	captures: []string, // Any captures.
	err: Pattern_Error, // An error with the pattern.
) {
	pattern := pattern
	if len(pattern) == 0 {
		err = .EmptyPattern
		return
	}

	anchor := pattern[0] == '^'
	if anchor do pattern = pattern[1:]

	{
		suffix_anchor := pattern[len(pattern) - 1] == '$'
		pat_no_suffix := pattern[:len(pattern) - 1]

		// For simple patterns, (no special chars, but can start with ^ or end with $).
		// We shortcut the check by using simple string comparison.
		if !contains_specials(pat_no_suffix) && (suffix_anchor || !contains_specials(pattern[len(pattern) - 1:])) {
			switch {
			// Both ^ and $, should check full equality.
			case anchor && suffix_anchor:
				if src != pat_no_suffix do return
				end = len(src)
			// Just $, should check suffix.
			case suffix_anchor:
				if !strings.has_suffix(src, pat_no_suffix) do return
				start = len(src) - len(pattern) + 1
				end = len(src)
			// Just ^, should check prefix.
			case anchor:
				if !strings.has_prefix(src, pattern) do return
				end = len(pattern) + 1
			// If we get here, there are no special characters at all, so check substring.
			case:
				i := strings.index(src, pattern)
				if i == -1 do return

				start = i
				end = i + len(pattern)
			}

			ok = true
			return
		}
	}

	ms: Match_State
	state_init(&ms, allocator)
	defer state_destroy(&ms)

	for i := 0; len(src) - i >= 0; i += 1 {
		res := match(&ms, src[i:], pattern) or_return
		if res == nil {
			if anchor do break
			continue
		}
		matched := res.(string)

		s := i
		e := len(src) - len(matched)

		captures = make([]string, ms.level, allocator)
		for j := 0; j < ms.level; j += 1 {
			captures[j] = (get_one_capture(&ms, j, src, matched) or_return)
		}

		return true, s, e, captures[0:ms.level], nil
	}

	return false, -1, -1, nil, nil
}

@(private)
GmatchIterData :: struct {
	src:       string,
	pattern:   string,
	allocator: mem.Allocator,
	start:     int,
	captures:  []string,
}

@(private="file")
@(thread_local)
data: GmatchIterData

// Globally match the pattern in the given string, instead of returning after the first match (like find).
// An iterator is returned, for example:
//
// for match in pattern.gmatch("hello", "(l)")() {
//    // i == 0, match == "l"
//    // i == 1, match == "l"
// }
gmatch :: proc(src, pattern: string, allocator := context.allocator) -> (proc() -> (match: string, ok: bool)) {
	data.allocator = allocator
	data.src = src
	data.pattern = pattern

	return proc() -> (match: string, ok: bool) {
		if len(data.captures) > 0 {
			data.captures = data.captures[1:]
			return data.captures[0], true
		}

		found, s, e, captures, err := find(data.src[data.start:], data.pattern, data.allocator)
		if err != nil {
			log.error(err)
			if data.captures != nil {
				delete(data.captures, data.allocator)
			}
			return
		}
		if !found {
			if data.captures != nil {
				delete(data.captures, data.allocator)
			}
			return
		}

		data.start += e

		if data.captures != nil {
			delete(data.captures, data.allocator)
		}
		data.captures = captures[1:]

		return captures[0], true
	}
}

// Escapes any special characters in val so that it is literally matched if used in a pattern.
escape :: proc(val: string, allocator := context.allocator) -> (res: string, was_allocation: bool) #optional_ok {
	if !contains_specials(val) do return val, false
	v, _, err := replace_all(val, "([%%^$%.+*?()%[%]-])", "%%%1", allocator)
	assert(err == .None) // pattern is fine.
	return v, true
}

// Replaces the first instance of pattern with replacement in the source string. In the
// string replacement, the character % works as an escape character: any sequence of
// the form %n, with n between 1 and 9, stands for the value of the nth
// captured substring due to the match with pattern. The sequence %0 stands for
// the entire match. The sequence %% stands for a single % in the resulting string.
//
// One "advanced" example to quote values in a key = value string, maintaining spacing:
//   pattern.replace("key =   value", "=(%s*)(%w+)", "=%1\"%2\"")
replace :: proc(src, pattern, replacement: string, allocator := context.allocator) -> (result: string, err: Pattern_Error) {
	result, _, err = replace_n(src, pattern, replacement, 1, allocator)
	return
}

// Same as replace but replaces all matches instead of one.
replace_all :: proc(src, pattern, replacement: string, allocator := context.allocator) -> (
	result: string,
	replaced: int,
	err: Pattern_Error,
) {
	return replace_n(src, pattern, replacement, -1, allocator)
}

// Same as replace but replaces up to max matches instead of one.
replace_n :: proc(src, pattern, replacement: string, max: int, allocator := context.allocator) -> (
	result: string,
	replaced: int,
	err: Pattern_Error,
) {
	pattern, src := pattern, src

	anchor := pattern[0] == '^'
	if anchor do pattern = pattern[1:]

	ms: Match_State
	state_init(&ms, allocator)
	defer state_destroy(&ms)

	buf: bytes.Buffer
	bytes.buffer_init_allocator(&buf, 0, len(src), allocator)

	n := 0
	for max == -1 || n < max {
		ms.level = 0
		matched := match(&ms, src, pattern) or_return

		if matched != nil {
			n += 1
			add_replacement(&ms, &buf, src, matched.(string), replacement) or_return

			if len(src) > 0 {
				src = matched.(string)
			}
		} else if len(src) > 0 {
			bytes.buffer_write_byte(&buf, src[0])
			src = src[1:]
		} else {
			break
		}

		if anchor do break
	}

	bytes.buffer_write_string(&buf, src)

	return bytes.buffer_to_string(&buf), n, nil
}

Pattern_Error :: enum {
	None,
	EmptyPattern,
	EndsWithPercent,
	EndsWithGroup,
	EmptyGroup,
	NotImplementedBalanced,
	InvalidCapture,
	UnfinishedCapture,
	MissingClosingBracket,
	AnchorInFindAll,
}

@(private)
CAPTURE_UNFINISHED :: -1

@(private)
Match_State :: struct {
	src:       string,
	level:     int,
	captures:  [dynamic]^Capture,
	allocator: mem.Allocator,
}

@(private)
state_init :: proc(ms: ^Match_State, allocator := context.allocator) {
	ms.allocator = allocator
	ms.captures = make([dynamic]^Capture, allocator)
}

@(private)
state_destroy :: proc(ms: ^Match_State) {
	for c in ms.captures do free(c, ms.allocator)
	delete(ms.captures)
}

@(private)
Capture :: struct {
	src: string,
	len: int,
}

@(private)
contains_specials :: proc(s: string) -> bool {
	return strings.contains_any(s, "^*+?.()[]%-$")
}

@(private)
match :: proc(ms: ^Match_State, src, pattern: string,) -> (matched: Maybe(string), err: Pattern_Error) {
	if len(pattern) == 0 do return src, nil

	switch pattern[0] {
	case '(':
		if len(pattern) == 1 do return nil, .EndsWithGroup
		if pattern[1] == ')' do return nil, .EmptyGroup
		return start_capture(ms, src, pattern[1:], CAPTURE_UNFINISHED)
	case ')':
		return end_capture(ms, src, pattern[1:])
	case '%':
		if len(pattern) == 1 do return nil, .EndsWithPercent
		if pattern[1] == 'b' do return nil, .NotImplementedBalanced

		if is_digit(pattern[1]) {
			new_src := match_capture(ms, src, int(pattern[1])) or_return
			if new_src == nil do return nil, nil
			return match(ms, new_src.(string), pattern[2:])
		}
	case '$':
		// Check that this is the end.
		if len(pattern) == 1 {
			if len(src) == 0 do return "", nil
			return nil, nil
		}
	}

	rest_pattern := class_end(ms, pattern) or_return
	matches := len(src) > 0 && single_match(src[0], pattern, rest_pattern)

	if len(rest_pattern) == 0 {
		if !matches do return nil, nil
		return match(ms, src[1:], rest_pattern)
	}

	switch rest_pattern[0] {
	case '?':
		// Success, this is optional.
		if len(src) == 0 do return "", nil

		res := match(ms, src[1:], rest_pattern[1:]) or_return
		if matches && res != nil do return res, nil
		return match(ms, src, rest_pattern[1:])
	case '*':
		return max_expand(ms, src, pattern, rest_pattern)
	case '+':
		if matches do return max_expand(ms, src[1:], pattern, rest_pattern)
		return nil, nil
	case '-':
		return min_expand(ms, src, pattern, rest_pattern)
	case:
		if !matches do return nil, nil
		return match(ms, src[1:], rest_pattern)
	}

	return nil, nil
}

@(private)
add_replacement :: proc(ms: ^Match_State, buf: ^bytes.Buffer, src, match, replacement: string) -> Pattern_Error {
	for i := 0; i < len(replacement); i += 1 {
		c := replacement[i]
		if c != '%' {
			bytes.buffer_write_byte(buf, c)
			continue
		}

		// Skip escaped character.
		i += 1
		c = replacement[i]

		switch {
		case !is_digit(c):
			bytes.buffer_write_byte(buf, c)
		case c == '0':
			bytes.buffer_write_string(buf, src[0:len(src) - len(match)])
		case:
			id := int(c - '1')
			bytes.buffer_write_string(buf, get_one_capture(ms, id, src, match) or_return)
		}
	}

	return nil
}

@(private)
get_one_capture :: proc(ms: ^Match_State, i: int, src, match: string) -> (string, Pattern_Error) {
	if i >= ms.level {
		if i != 0 {
			return "", .InvalidCapture
		}

		return src[0:len(src) - len(match)], nil
	}

	len := ms.captures[i].len
	if len == CAPTURE_UNFINISHED {
		return "", .UnfinishedCapture
	}

	return ms.captures[i].src[0:len], nil
}

// Sets up the match state to start a capture, and attempts to finish the match
// with that capture in place. If the further match fails, the capture is
// undone, otherwise the match is returned.
@(private)
start_capture :: proc(ms: ^Match_State, src, pattern: string, what: int,) -> (matched: Maybe(string), err: Pattern_Error) {
	if len(ms.captures) <= ms.level {
		cap := new(Capture, ms.allocator)
		append(&ms.captures, cap)
	}

	ms.captures[ms.level].src = src
	ms.captures[ms.level].len = what

	ms.level += 1

	mat := match(ms, src, pattern) or_return
	if mat == nil do ms.level -= 1

	return mat, err
}

// Ends the current capture and tries to match the rest of the pattern.
// If the match fails, the capture is undone.
@(private)
end_capture :: proc(ms: ^Match_State, src, pattern: string,) -> (matched: Maybe(string), err: Pattern_Error) {
	level := capture_to_close(ms)
	if level == -1 do return nil, nil

	ms.captures[level].len = len(ms.captures[level].src) - len(src)

	mat := match(ms, src, pattern) or_return
	if mat == nil do ms.captures[level].len = CAPTURE_UNFINISHED
	return mat, err
}

// Returns the first level that contains an unclosed capture, or -1 if there is
// no such capture level.
@(private)
capture_to_close :: proc(ms: ^Match_State) -> int {
	for level := ms.level - 1; level >= 0; level -= 1 {
		if ms.captures[level].len == CAPTURE_UNFINISHED {
			return level
		}
	}

	return -1
}

// Matches a previous capture by checking if it exists and then skipping over the length of it.
// Returns the src with the capture removed.
@(private)
match_capture :: proc(ms: ^Match_State, src: string, level: int,) -> (rest: Maybe(string), err: Pattern_Error) {
	target_level := check_capture(ms, level) or_return
	target_len := ms.captures[target_level].len

	// Ensure there is enough space to accommodate the match.
	if len(src) - target_len >= 0 &&
	   ms.captures[target_level].src[0:target_len] == src[0:target_len] {
		return src[target_len:], nil
	}

	return nil, nil
}

// Checks if a capture exists with the given capture index.
@(private)
check_capture :: proc(ms: ^Match_State, level: int) -> (int, Pattern_Error) {
	l := level - 1
	if l < 0 || l >= ms.level || ms.captures[l].len == CAPTURE_UNFINISHED {
		return -1, .InvalidCapture
	}

	return l, nil
}

// Return the maximum portion of the source string that matches the given pattern (equates to the '+' or '*' operator).
@(private)
max_expand :: proc(ms: ^Match_State, src, pattern, rest_pattern: string) -> (matched: Maybe(string), err: Pattern_Error) {
	i: int
	for ; i < len(src) && single_match(src[i], pattern, rest_pattern); i += 1 {}

	for ; i >= 0; i -= 1 {
		mat := match(ms, src[i:], rest_pattern[1:]) or_return
		if mat != nil do return mat, nil
	}

	return nil, nil
}

// Returns the minimum portion of the source string that matches the given pattern (equates to the '-' operator).
@(private)
min_expand :: proc(ms: ^Match_State, src, pattern, rest_pattern: string,) -> (matched: Maybe(string), err: Pattern_Error) {
	src := src
	for {
		mat := match(ms, src, rest_pattern[1:]) or_return
		if mat != nil {
			return mat, nil
		}

		// Increase match and try again.
		if len(src) > 0 && single_match(src[0], pattern, rest_pattern) {
			src = src[1:]
			continue
		}

		return nil, nil
	}

	return nil, nil
}


// Finds the end of a character class [] and returns the pattern after the ending ']' or the full pattern.
@(private)
class_end :: proc(ms: ^Match_State, pattern: string) -> (matched: string, err: Pattern_Error) {
	pattern := pattern

	ch := pattern[0]
	pattern = pattern[1:]

	switch ch {
	// Skip next, allows '%[' to escape the '['.
	case '%':
		if len(pattern) == 0 {
			return "", .EndsWithPercent
		}

		return pattern[1:], nil
	case '[':
		if pattern[0] == '^' do pattern = pattern[1:]

		// Look for closing ']'
		for {
			if len(pattern) == 0 {
				return "", .MissingClosingBracket
			}

			pch := pattern[0]
			pattern = pattern[1:]

			// Skip escaped '%]'
			if pch == '%' && len(pattern) > 0 do pattern = pattern[1:]

			// Found closing ']'
			if len(pattern) > 0 && pattern[0] == ']' do break
		}

		return pattern[1:], nil

	case:
		return pattern, nil
	}
}

// Returns whether or not a single character matches the pattern currently being examined.
@(private)
single_match :: proc(ch: byte, pattern, rest_pattern: string) -> bool {
	switch pattern[0] {
	case '.': return true
	case '%': return match_class(ch, pattern[1])
	case '[': return match_bracket_class(ch, pattern, pattern[len(pattern) - len(rest_pattern) - 1:])
	case:     return pattern[0] == ch
	}
}

// Returns whether or not a given character matches the character class
// specified in the pattern. The pattern here is anything in between the [ and ].
@(private)
match_bracket_class :: proc(ch: byte, pattern, rest_pattern: string) -> bool {
	pattern := pattern

	// Starting with a ^ negates the pattern.
	compliment := true
	if pattern[1] == '^' {
		compliment = false
		pattern = pattern[1:]
	}

	for pattern = pattern[1:]; len(pattern) > len(rest_pattern); pattern = pattern[1:] {
		switch {
		// Match a predefined % class.
		case pattern[0] == '%':
			pattern = pattern[1:]
			if match_class(ch, pattern[0]) do return compliment
		// Match a character range eg. A-Z
		case pattern[1] == '-' && (len(pattern) - 2 > len(rest_pattern)):
			if pattern[0] <= ch && ch <= pattern[2] do return compliment
		// Match the literal character.
		case pattern[0] == ch:
			return compliment
		}
	}

	return !compliment
}

// Match a character class eg. '%a'.
@(private)
match_class :: proc(ch: byte, class: byte) -> (res: bool) {
	class_lower := to_lower(class)
	switch class_lower {
	case 'a': res = is_alpha(ch)
	case 'c': res = is_cntrl(ch) // Carriage returns, newlines, tabs...
	case 'd': res = is_digit(ch)
	case 'l': res = is_lower(ch)
	case 'p': res = is_punct(ch)
	case 's': res = is_space(ch)
	case 'u': res = is_upper(ch)
	case 'w': res = is_alnum(ch)
	case 'x': res = is_x_digit(ch) // hexadecimal.
	case 'z': res = ch == 0
	case:
		return class == ch
	}

	return is_lower(class) ? res : !res
}

@(private)
is_lower :: proc(b: byte) -> bool {return b >= 'a' && b <= 'z'}

@(private)
is_upper :: proc(b: byte) -> bool {return b >= 'A' && b <= 'Z'}

@(private)
to_lower :: proc(b: byte) -> byte {
	if is_upper(b) do return b + 32
	return b
}

@(private)
is_alpha :: proc(b: byte) -> bool {return is_lower(b) || is_upper(b)}

// Carriage returns, newlines, tabs...
@(private)
is_cntrl :: proc(b: byte) -> bool {
	return(
		b <= '\007' ||
		(b >= '\010' && b <= '\017') ||
		(b >= '\020' && b <= '\027') ||
		(b >= '\030' && b <= '\037') ||
		b == '\177' \
	)
}

@(private)
is_digit :: proc(b: byte) -> bool {return b >= 48 && b <= 57}

@(private)
is_punct :: proc(b: byte) -> bool {
	return(
		(b >= '{' && b <= '~') ||
		(b == '`') ||
		(b >= '[' && b <= '_') ||
		(b == '@') ||
		(b >= ':' && b <= '?') ||
		(b >= '(' && b <= '/') ||
		(b >= '!' && b <= '\'') \
	)
}

@(private)
is_space :: proc(b: byte) -> bool {return(
		b == '\t' ||
		b == '\n' ||
		b == '\v' ||
		b == '\f' ||
		b == '\r' ||
		b == ' ' \
	)}

@(private)
is_alnum :: proc(b: byte) -> bool {return is_alpha(b) || is_digit(b)}

// Hexadecimal digit.
@(private)
is_x_digit :: proc(b: byte) -> bool {return(
		is_digit(b) ||
		(b >= 'a' && b <= 'f') ||
		(b >= 'A' && b <= 'F') \
	)}
