package http

import "core:strings"
import "core:unicode"
import "core:bytes"
import "core:io"
import "core:time"
import "core:slice"
import "core:strconv"

// **WARNING: DO NOT ACCESS THIS DIRECTLY**, use the `header_get_*`, `header_update_*` and `header_set_*` procedures.
Headers :: distinct map[string]string

/*
Get a header value by an unknown or generic key.

If the key contains any upper case characters, the given allocator is used to make a lower case variant for comparison.

Have a look at the other header_get_* procedures for faster alternatives when you know more about the key.
*/
header_get_key_unknown :: proc(bag: Headers, unknown_key: string, allocator := context.temp_allocator) -> (string, bool) #optional_ok {
	_assert_headers_state(bag)
	key := _header_unknown_key_to_lower(unknown_key, allocator)
	return bag[key]
}

/*
Sets a header by an unknown or generic key, returning the previous value if there.

If the key contains any upper case characters, the given allocator is used to make a lower case variant for insertion.

Have a look at the other header_update_* procedures for faster alternatives when you know more about the key.
*/
header_update_key_unknown :: proc(bag: ^Headers, unknown_key: string, value: string, allocator := context.temp_allocator) -> (key: string, prev_value: string, has_prev: bool) {
	_assert_headers_state(bag^)
	key = _header_unknown_key_to_lower(unknown_key, allocator)
	prev_value, has_prev = bag[key]
	bag[key] = value
	return
}

/*
Sets a header by an unknown or generic key.

If the key contains any upper case characters, the given allocator is used to make a lower case variant for insertion.

Have a look at the other header_set_* procedures for alternatives when you know more/less about the key.
*/
header_set_key_unknown :: proc(bag: ^Headers, unknown_key: string, value: string, allocator := context.temp_allocator) {
	_assert_headers_state(bag^)
	key :=_header_unknown_key_to_lower(unknown_key, allocator)
	bag[key] = value
}

/*
Get a header value by a key of unknown case, that is safe to be mutated.

If the key contains any upper case characters, they are converted to lowercase in-place.

Have a look at the other header_get_* procedures for alternatives when you know more/less about the key.
*/
header_get_key_mutable :: proc(bag: Headers, mutable_key: ^[]byte) -> (string, bool) #optional_ok {
	_assert_headers_state(bag)
	_header_mutable_key_to_lower(mutable_key)
	key := string(mutable_key^)
	return bag[key]
}

/*
Sets a header by an unknown or generic key that is mutable, returning the previous value if there.

If the key contains any upper case characters, the key is lower cased in-place.

Have a look at the other header_update_* procedures for faster alternatives when you know more/less about the key.
*/
header_update_key_mutable :: proc(bag: ^Headers, mutable_key: ^[]byte, value: string) -> (prev_value: string, has_prev: bool) {
	_assert_headers_state(bag^)
	_header_mutable_key_to_lower(mutable_key)
	key := string(mutable_key^)
	prev_value, has_prev = bag[key]
	bag[key] = value
	return
}

/*
Sets a header by an unknown or generic key that is mutable.

If the key contains any upper case characters, the key is lower cased in-place.

*Have a look at the other header_set_* procedures for alternatives when you know more/less about the key.
*/
header_set_key_mutable :: proc(bag: ^Headers, mutable_key: ^[]byte, value: string) {
	_assert_headers_state(bag^)
	_header_mutable_key_to_lower(mutable_key)
	key := string(mutable_key^)
	bag[key] = value
}

/*
Get a header value by a key of which you know is lower case, generally string literals.

In debug mode, the key is asserted to be a lower case string to catch errors, this is turned of on
other modes.

Have a look at the other header_get_* procedures for alternatives when you know less about the key.
*/
header_get_key_lower :: #force_inline proc(bag: Headers, lower_case_key: string) -> (string, bool) #optional_ok {
	_assert_lowercase_key(lower_case_key)
	_assert_headers_state(bag)
	return bag[lower_case_key]
}

/*
Set a header value by a key of which you know is lower case, generally string literals, and return the previous value.

In debug mode, the key is asserted to be a lower case string to catch errors, this is turned of on
other modes.

Have a look at the other header_update_* procedures for alternatives when you know less about the key.
*/
header_update_key_lower :: proc(bag: ^Headers, lower_case_key: string, value: string) -> (prev_value: string, has_prev: bool) {
	_assert_lowercase_key(lower_case_key)
	_assert_headers_state(bag^)
	prev_value, has_prev = bag[lower_case_key]
	bag[lower_case_key] = value
	return
}

/*
Set a header value by a key of which you know is lower case, generally string literals.

In debug mode, the key is asserted to be a lower case string to catch errors, this is turned of on
other modes.

Have a look at the other header_set_* procedures for alternatives when you know less about the key.
*/
header_set_key_lower :: #force_inline proc(bag: ^Headers, lower_case_key: string, value: string) {
	_assert_lowercase_key(lower_case_key)
	_assert_headers_state(bag^)
	bag[lower_case_key] = value
}

/*
Deletes a header by a key of which you know is lower case, generally string literals.

In debug mode, the key is asserted to be a lower case string to catch errors, this is turned of on
other modes.

Have a look at the other header_delete_* procedures for alternatives when you know less about the key.
// TODO: other header_delete_* procs.
*/
header_delete_key_lower :: #force_inline proc(bag: ^Headers, lower_case_key: string) -> (deleted_key: string, deleted_value: string) {
	_assert_lowercase_key(lower_case_key)
	_assert_headers_state(bag^)
	return delete_key(bag, lower_case_key)
}

/*
Writes the header into the given writer, escaping newlines.

A common HTTP attack vector is putting newlines into user input that is then put in a header.

TODO: test this.
*/
header_write :: proc(w: io.Writer, key: string, value: string) {
	_write_escaped_newlines(w, key)
	io.write_string(w, ": ")
	_write_escaped_newlines(w, value)
	io.write_string(w, "\r\n")
}

header_parse :: proc(headers: ^Headers, line: string, allocator := context.allocator) -> (key: string, ok: bool) {
	// Preceding spaces should not be allowed.
	(len(line) > 0 && line[0] != ' ') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	key = line[:colon]
	value := strings.trim_space(line[colon + 1:])

	bkey := transmute([]byte)key
	prev, has_prev := header_update_key_mutable(headers, &bkey, value)

	if has_prev {
		// RFC 7230 5.4: Server MUST respond with 400 to any request
		// with multiple "Host" header fields.
		if key == "host" {
			return
		}

		if key == "content-length" {
			// RFC 7230 3.3.3: If a message is received without Transfer-Encoding and with
			// either multiple Content-Length header fields having differing
			// field-values or a single Content-Length header field having an
			// invalid value, then the message framing is invalid and the
			// recipient MUST treat it as an unrecoverable error.
			if value != prev {
				return
			}
		}
	}

	ok = true
	return
}

@(private="file")
DISALLOWED_TRAILER := map[string]struct{}{
	// Message framing:
	"transfer-encoding" = {},
	"content-length" = {},
	// Routing:
	"host" = {},
	// Request modifiers:
	"if-match" = {},
	"if-none-match" = {},
	"if-modified-since" = {},
	"if-unmodified-since" = {},
	"if-range" = {},
	// Authentication:
	"www-authenticate" = {},
	"authorization" = {},
	"proxy-authenticate" = {},
	"proxy-authorization" = {},
	"cookie" = {},
	"set-cookie" = {},
	// Control data:
	"age" = {},
	"cache-control" = {},
	"expires" = {},
	"date" = {},
	"location" = {},
	"retry-after" = {},
	"vary" = {},
	"warning" = {},
	// How to process:
	"content-encoding" = {},
	"content-type" = {},
	"content-range" = {},
	"trailer" = {},
}

// Returns if this is a valid trailer header.
//
// RFC 7230 4.1.2:
// A sender MUST NOT generate a trailer that contains a field necessary
// for message framing (e.g., Transfer-Encoding and Content-Length),
// routing (e.g., Host), request modifiers (e.g., controls and
// conditionals in Section 5 of [RFC7231]), authentication (e.g., see
// [RFC7235] and [RFC6265]), response control data (e.g., see Section
// 7.1 of [RFC7231]), or determining how to process the payload (e.g.,
// Content-Encoding, Content-Type, Content-Range, and Trailer).
header_allowed_trailer :: proc(key: string) -> bool {
	return key not_in DISALLOWED_TRAILER
}

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT
write_date_header :: proc(w: io.Writer, t: time.Time) -> io.Error {

	write_padded_int :: proc(w: io.Writer, i: int) -> io.Error {
		if i < 10 {
			io.write_string(w, PADDED_NUMS[i]) or_return
			return nil
		}

		_, err := io.write_int(w, i)
		return err
	}

	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	wday := time.weekday(t)

	// odinfmt:disable
	io.write_string(w, DAYS[wday])    or_return // 'Fri, '
	write_padded_int(w, day)          or_return // 'Fri, 05'
	io.write_string(w, MONTHS[month]) or_return // 'Fri, 05 Feb '
	io.write_int(w, year)             or_return // 'Fri, 05 Feb 2023'
	io.write_byte(w, ' ')             or_return // 'Fri, 05 Feb 2023 '
	write_padded_int(w, hour)         or_return // 'Fri, 05 Feb 2023 09'
	io.write_byte(w, ':')             or_return // 'Fri, 05 Feb 2023 09:'
	write_padded_int(w, minute)       or_return // 'Fri, 05 Feb 2023 09:01'
	io.write_byte(w, ':')             or_return // 'Fri, 05 Feb 2023 09:01:'
	write_padded_int(w, second)       or_return // 'Fri, 05 Feb 2023 09:01:10'
	io.write_string(w, " GMT")        or_return // 'Fri, 05 Feb 2023 09:01:10 GMT'
	// odinfmt:enable

	return nil
}

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT
format_date_header :: proc(t: time.Time, allocator := context.allocator) -> string {
	b: strings.Builder

	buf := make([]byte, DATE_LENGTH, allocator)
	b.buf = slice.into_dynamic(buf)

	write_date_header(strings.to_writer(&b), t)

	return strings.to_string(b)
}

parse_date_header :: proc(value: string) -> (t: time.Time, ok: bool) #no_bounds_check {
	if len(value) != DATE_LENGTH do return

	// Remove 'Fri, '
	value := value
	value = value[5:]

	// Parse '05'
	day := strconv.atoi(value[:2])
	value = value[2:]

	// Parse ' Feb ' or '-Feb-' (latter is a deprecated format but should still be parsed).
	month_index := -1
	month_str := value[1:4]
	value = value[5:]
	for month, i in MONTHS[1:] {
		if month_str == month[1:4] {
			month_index = i
			break
		}
	}
	month_index += 1
	if month_index <= 0 do return

	year := strconv.parse_int(value[:4], 10) or_return
	value = value[4:]

	hour := strconv.parse_int(value[1:3], 10) or_return
	value = value[4:]

	minute := strconv.parse_int(value[:2], 10) or_return
	value = value[3:]

	seconds := strconv.parse_int(value[:2], 10) or_return
	value = value[3:]

	// Should have only 'GMT' left now.
	if value != "GMT" do return

	t = time.datetime_to_time(year, month_index, day, hour, minute, seconds) or_return
	ok = true
	return
}

// TODO: test
_header_unknown_key_to_lower :: proc(key: string, allocator := context.temp_allocator) -> string {
	// Assumes that header keys are ASCII, which, if I look at other implementations, is correct.
	for i in 0..<len(key) {
		c := key[i]
		if c > unicode.MAX_ASCII {
			continue
		}

		is_lower := u32(c)-'a' < 26
		if is_lower {
			continue
		}

		// Non lower case detected, need to make a lowercase variant to compare.
		buf := make([]byte, len(key), allocator)
		defer delete(buf)

		for i in 0..<len(key) {
			lower := key[i] + 32

			// Conversion resulted in a valid lower case character.
			if lower >= 97 && lower <= 122 {
				buf[i] = lower
				continue
			}

			buf[i] = key[i]
		}

		return string(buf)
	}

	return key
}

// TODO: test
_header_mutable_key_to_lower :: proc(key: ^[]byte) {
	// Assumes that header keys are ASCII, which, if I look at other implementations, is correct.
	for c, i in key {
		if c > unicode.MAX_ASCII {
			continue
		}

		lower := c + 32

		// Conversion resulted in a valid lower case character.
		if lower >= 97 && lower <= 122 {
			key[i] = lower
		}
	}

}

@(private)
DATE_LENGTH :: len("Fri, 05 Feb 2023 09:01:10 GMT")

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

@(disabled=ODIN_DISABLE_ASSERT || !ODIN_DEBUG)
_assert_lowercase_key :: proc(key: string, loc := #caller_location) {
	for c in key {
		assert(
			unicode.is_lower(c),
			"header keys are always lowercase and should be retrieved using lowercase keys",
			loc,
		)
	}
}

@(disabled=ODIN_DISABLE_ASSERT || !ODIN_DEBUG)
_assert_headers_state :: proc(bag: Headers, loc := #caller_location) {
	for k in bag {
		_assert_lowercase_key(k, loc)
	}
}
