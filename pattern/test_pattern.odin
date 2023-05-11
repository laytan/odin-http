package pattern

import "core:testing"
import "core:fmt"

expect  :: testing.expect
log     :: testing.log

expect_equal ::proc(t: ^testing.T, first: $T, second: $K, extra := "") {
	expect(t, first == second, fmt.tprintf("%v != %v (%s)", first, second, extra))
}

expect_find :: proc(t: ^testing.T, src, pat: string, ok: bool, start, end: int, captures: []string, err: Pattern_Error) {
	aok, astart, aend, acaptures, aerr := find(src, pat)
	expect_equal(t, aerr, err, pat)
	expect_equal(t, astart, start, pat)
	expect_equal(t, aend, end, pat)
	expect_equal(t, aok, ok, pat)
	expect_equal(t, len(acaptures), len(captures), "find captures length")
	for i := 0; i < len(acaptures); i += 1 {
		expect_equal(t, acaptures[i], captures[i], fmt.tprintf("find capture %i", i))
	}
}

@(test)
test_find :: proc(t: ^testing.T) {
	expect_find(t, "aaab", ".*b", true, 0, 4, []string{}, nil)
	expect_find(t, "aaa", ".*a", true, 0, 3, []string{}, nil)
	expect_find(t, "b", ".*b", true, 0, 1, []string{}, nil)

	expect_find(t, "aaab", ".+b", true, 0, 4, []string{}, nil)
	expect_find(t, "aaa", ".+a", true, 0, 3, []string{}, nil)
	expect_find(t, "b", ".+b", false, -1, -1, []string{}, nil)

	expect_find(t, "aaab", ".?b", true, 2, 4, []string{}, nil)
	expect_find(t, "aaa", ".?a", true, 0, 2, []string{}, nil)
	expect_find(t, "b", ".?b", true, 0, 1, []string{}, nil)

	expect_find(t, "alo xyzK", "(%w+)K", true, 4, 8, []string{"xyz"}, nil)
	expect_find(t, "254 K", "(%d*)K", true, 4, 5, []string{""}, nil)
	expect_find(t, "alo ", "(%w*)$", true, 4, 4, []string{""}, nil)
	expect_find(t, "alo ", "(%w+)$", false, -1, -1, []string{}, nil)

	expect_find(t, "testtset", "^(tes(t+)set)$", true, 0, 8, []string{"testtset", "tt"}, nil)

	expect_find(t, "", "", false, 0, 0, []string{}, Pattern_Error.EmptyPattern)

	expect_find(t, "aloALO", "%l*", true, 0, 3, []string{}, nil)
	expect_find(t, "aLo_ALO", "%a*", true, 0, 3, []string{}, nil)
	expect_find(t, "aaa", "^.*$", true, 0, 3, []string{}, nil)
	expect_find(t, "aaa", "a*a", true, 0, 3, []string{}, nil)
	expect_find(t, "a$a", ".$.", true, 0, 3, []string{}, nil)

	expect_find(t, "aaab", "a-", true, 0, 0, []string{}, nil)
	expect_find(t, "aaa", "^.-$", true, 0, 3, []string{}, nil)

	expect_find(t, "alo xo", ".o$", true, 4, 6, []string{}, nil)
	expect_find(t, "um caracter ? extra", "[^%sa-z]", true, 12, 13, []string{}, nil)

	expect_find(t, "á", "á?", true, 0, 2, []string{}, nil)
	expect_find(t, "(álo)", "%(á", true, 0, 3, []string{}, nil)

	expect_find(t, "abc", "abc", true, 0, 3, []string{}, nil)
	expect_find(t, "abcdefg", "^abc", true, 0, 4, []string{}, nil)
	expect_find(t, "abcdefgabc", "abc$", true, 7, 10, []string{}, nil)
	expect_find(t, "abc", "^abc$", true, 0, 3, []string{}, nil)
	expect_find(t, "abbc", "^abc$", false, 0, 0, []string{}, nil)

	expect_find(t, "/users/laytan", "^/users/(%w+)$", true, 0, 13, []string{"laytan"}, nil)
	expect_find(t, "/p/users/laytan", "^/users/(%w+)$", false, -1, -1, []string{}, nil)
	expect_find(t, "/p/users/laytan", "/users/(%w+)$", true, 2, 15, []string{"laytan"}, nil)
	expect_find(t, "/users/laytan/testing", "^/users/(%w+)", true, 0, 13, []string{"laytan"}, nil)
	expect_find(t, "/users/laytan/testing", "^/users/(%w+)/(.*)", true, 0, 21, []string{"laytan", "testing"}, nil)

	expect_find(t, "/users/laytan/testing?hello=world&next-time=none", "%?([^&/?]*)", true, 21, 33, []string{"hello=world"}, nil)

	expect_find(t, "/users/laytan/testing?hello=world&next-time=none", "%?([^&/?]*)", true, 21, 33, []string{"hello=world"}, nil)
}

@(test)
test_escape :: proc(t: ^testing.T) {
	expect_equal(t, escape("he%yo$, *."), "he%%yo%$, %*%.")
}

@(test)
test_replace :: proc(t: ^testing.T) {
	rp, err := replace("key =   value", "=(%s*)(%w+)", "=%1\"%2\"")
	expect_equal(t, err, Pattern_Error.None)
	expect_equal(t, rp, "key =   \"value\"")
}
