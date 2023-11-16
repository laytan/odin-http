package job

import "core:testing"
import "core:fmt"
import "core:strings"

@(test)
test_job_args :: proc(t: ^testing.T) {
	@static tt: ^testing.T
	tt = t

	job := batch(
		new1(u8(5), proc(j: ^Job, m: Handle_Mode, d: u8) {
			testing.expect_value(tt, d, 5)
			done(j)
		}),
		new1(u128(5), proc(j: ^Job, m: Handle_Mode, d: u128) {
			testing.expect_value(tt, d, 5)
			done(j)
		}),
		new2(u64(5), u64(513), proc(j: ^Job, m: Handle_Mode, d: u64, d2: u64) {
			testing.expect_value(tt, d, 5)
			testing.expect_value(tt, d2, 513)
			done(j)
		}),
	)
	defer destroy(job, .Down)

	testing.log(t, job)

	run(job)

	testing.log(t, job)
}

@(test)
test_job_format :: proc(t: ^testing.T) {
	dummy := proc(j: ^Job, m: Handle_Mode, d: u8) {}

	job := batch(
		chain(
			new1(u8(4), dummy, "job1"),
			new1(u8(4), dummy, "job2"),
		),
		chain(
			new1(u8(4), dummy, "job3"),
			new1(u8(4), dummy, "job4"),
		),
	)
	defer destroy(job, .Down)

	testing.log(t, job)

	// link
	testing.expect_value(t, job.chain, nil)
	testing.expect_value(t, job.batch.name, "job1")

	// job1
	testing.expect_value(t, job.batch.batch.name, "job3")
	testing.expect_value(t, job.batch.chain.name, "job2")

	// job2
	testing.expect_value(t, job.batch.chain.chain, nil)
	testing.expect_value(t, job.batch.chain.batch, nil)

	// job3
	testing.expect_value(t, job.batch.batch.chain.name, "job4")
	testing.expect_value(t, job.batch.batch.batch, nil)

	// job4
	testing.expect_value(t, job.batch.batch.chain.chain, nil)
	testing.expect_value(t, job.batch.batch.chain.batch, nil)

	expected: string : "& job1 ->        job2 \n  job3 ->  job4"
	fmt_output := strings.trim_space(fmt.tprint(job))
	testing.expect_value(t, fmt_output, expected)
}

