//+build linux
package io_uring

import "core:intrinsics"

//odinfmt:disable
SYS_io_uring_setup:    uintptr : 425
SYS_io_uring_enter:    uintptr : 426
SYS_io_uring_register: uintptr : 427
//odinfmt:enable

NSIG :: 65

sigset_t :: [1024 / 32]u32

io_uring_params :: struct {
	sq_entries:     u32,
	cq_entries:     u32,
	flags:          u32,
	sq_thread_cpu:  u32,
	sq_thread_idle: u32,
	features:       u32,
	wq_fd:          u32,
	resv:           [3]u32,
	sq_off:         io_sqring_offsets,
	cq_off:         io_cqring_offsets,
}
#assert(size_of(io_uring_params) == 120)

io_sqring_offsets :: struct {
	head:         u32,
	tail:         u32,
	ring_mask:    u32,
	ring_entries: u32,
	flags:        u32,
	dropped:      u32,
	array:        u32,
	resv1:        u32,
	user_addr:    u64,
}

io_cqring_offsets :: struct {
	head:         u32,
	tail:         u32,
	ring_mask:    u32,
	ring_entries: u32,
	overflow:     u32,
	cqes:         u32,
	flags:        u32,
	resv1:        u32,
	user_addr:    u64,
}

// Submission queue entry.
io_uring_sqe :: struct {
	opcode:           IORING_OP, // u8
	flags:            u8, /* IOSQE_ flags */
	ioprio:           u16, /* ioprio for the request */
	fd:               i32, /* file descriptor to do IO on */
	using __offset:   struct #raw_union {
		off:     u64, /* offset into file */
		addr2:   u64,
		using _: struct {
			cmd_op: u32,
			__pad1: u32,
		},
	},
	using __iovecs:   struct #raw_union {
		addr:          u64, /* pointer to buffer or iovecs */
		splice_off_in: u64,
	},
	len:              u32, /* buffer size or number of iovecs */
	using __contents: struct #raw_union {
		rw_flags:         i32,
		fsync_flags:      u32,
		poll_events:      u16, /* compatibility */
		poll32_events:    u32, /* word-reversed for BE */
		sync_range_flags: u32,
		msg_flags:        u32,
		timeout_flags:    u32,
		accept_flags:     u32,
		cancel_flags:     u32,
		open_flags:       u32,
		statx_flags:      u32,
		fadvise_advice:   u32,
		splice_flags:     u32,
		rename_flags:     u32,
		unlink_flags:     u32,
		hardlink_flags:   u32,
		xattr_flags:      u32,
		msg_ring_flags:   u32,
		uring_cmd_flags:  u32,
	},
	user_data:        u64, /* data to be passed back at completion time */
	/* pack this to avoid bogus arm OABI complaints */
	using __buffer:   struct #raw_union {
		/* index into fixed buffers, if used */
		buf_index: u16,
		/* for grouped buffer selection */
		buf_group: u16,
	},
	/* personality to use, if used */
	personality:      u16,
	using _:          struct #raw_union {
		splice_fd_in: i32,
		file_index:   u32,
		using _:      struct {
			addr_len: u16,
			__pad3:   [1]u16,
		},
	},
	using __:         struct #raw_union {
		using _: struct {
			addr3:  u64,
			__pad2: [1]u64,
		},
		/*
		 * If the ring is initialized with IORING_SETUP_SQE128, then
		 * this field is used for 80 bytes of arbitrary command data
		 * NOTE: This is currently not supported.
		 */
		// cmd:     [^]u8,
	},
}
#assert(size_of(io_uring_sqe) == 64)

// Completion queue entry.
io_uring_cqe :: struct {
	user_data: u64, /* sq.data submission passed back */
	res:       i32, /* result code for this event */
	flags:     u32,
	/*
	 * If the ring is initialized with IORING_SETUP_CQE32, then this field
	 * contains 16-bytes of padding, doubling the size of the CQE.
	 * NOTE: This is currently not supported.
	 */
	// big_cqe:   [^]u64,
}
#assert(size_of(io_uring_cqe) == 16)

/*
 * sqe.flags
 */
/* use fixed fileset */
IOSQE_FIXED_FILE: u32 : (1 << 0)
/* issue after inflight IO */
IOSQE_IO_DRAIN: u32 : (1 << 1)
/* links next sqe */
IOSQE_IO_LINK: u32 : (1 << 2)
/* like LINK, but stronger */
IOSQE_IO_HARDLINK: u32 : (1 << 3)
/* always go async */
IOSQE_ASYNC: u32 : (1 << 4)
/* select buffer from sq.buf_group */
IOSQE_BUFFER_SELECT: u32 : (1 << 5)
/* don't post CQE if request succeeded */
IOSQE_CQE_SKIP_SUCCESS: u32 : (1 << 6)

/*
 * io_uring_setup() flags
 */
IORING_SETUP_IOPOLL: u32 : (1 << 0) /* io_context is polled */
IORING_SETUP_SQPOLL: u32 : (1 << 1) /* SQ poll thread */
IORING_SETUP_SQ_AFF: u32 : (1 << 2) /* sq_thread_cpu is valid */
IORING_SETUP_CQSIZE: u32 : (1 << 3) /* app defines CQ size */
IORING_SETUP_CLAMP: u32 : (1 << 4) /* clamp SQ/CQ ring sizes */
IORING_SETUP_ATTACH_WQ: u32 : (1 << 5) /* attach to existing wq */
IORING_SETUP_R_DISABLED: u32 : (1 << 6) /* start with ring disabled */
IORING_SETUP_SUBMIT_ALL: u32 : (1 << 7) /* continue submit on error */
// Cooperative task running. When requests complete, they often require
// forcing the submitter to transition to the kernel to complete. If this
// flag is set, work will be done when the task transitions anyway, rather
// than force an inter-processor interrupt reschedule. This avoids interrupting
// a task running in userspace, and saves an IPI.
IORING_SETUP_COOP_TASKRUN: u32 : (1 << 8)
// If COOP_TASKRUN is set, get notified if task work is available for
// running and a kernel transition would be needed to run it. This sets
// IORING_SQ_TASKRUN in the sq ring flags. Not valid with COOP_TASKRUN.
IORING_SETUP_TASKRUN_FLAG: u32 : (1 << 9)
IORING_SETUP_SQE128: u32 : (1 << 10) /* SQEs are 128 byte */
IORING_SETUP_CQE32: u32 : (1 << 11) /* CQEs are 32 byte */
// Only one task is allowed to submit requests
IORING_SETUP_SINGLE_ISSUER: u32 : (1 << 12)
// Defer running task work to get events.
// Rather than running bits of task work whenever the task transitions
// try to do it just before it is needed.
IORING_SETUP_DEFER_TASKRUN: u32 : (1 << 13)

/*
 * sqe.uring_cmd_flags
 * IORING_URING_CMD_FIXED	use registered buffer; pass this flag
 *				along with setting sqe.buf_index.
 */
IORING_URING_CMD_FIXED: u32 : (1 << 0)

/*
 * sqe.fsync_flags
 */
IORING_FSYNC_DATASYNC: u32 : (1 << 0)

/*
 * sqe.timeout_flags
 */
IORING_TIMEOUT_ABS: u32 : (1 << 0)
IORING_TIMEOUT_UPDATE: u32 : (1 << 1)
IORING_TIMEOUT_BOOTTIME: u32 : (1 << 2)
IORING_TIMEOUT_REALTIME: u32 : (1 << 3)
IORING_LINK_TIMEOUT_UPDATE: u32 : (1 << 4)
IORING_TIMEOUT_ETIME_SUCCESS: u32 : (1 << 5)
IORING_TIMEOUT_CLOCK_MASK: u32 : (IORING_TIMEOUT_BOOTTIME | IORING_TIMEOUT_REALTIME)
IORING_TIMEOUT_UPDATE_MASK: u32 : (IORING_TIMEOUT_UPDATE | IORING_LINK_TIMEOUT_UPDATE)

/*
 * sq_ring.flags
 */
IORING_SQ_NEED_WAKEUP: u32 : (1 << 0) /* needs io_uring_enter wakeup */
IORING_SQ_CQ_OVERFLOW: u32 : (1 << 1) /* CQ ring is overflown */
IORING_SQ_TASKRUN: u32 : (1 << 2) /* task should enter the kernel */

/*
 * sqe.splice_flags
 * extends splice(2) flags
 */
SPLICE_F_FD_IN_FIXED: u32 : (1 << 31) /* the last bit of __u32 */

/*
 * POLL_ADD flags. Note that since sqe.poll_events is the flag space, the command flags for POLL_ADD are stored in sqe.len.
 *
 * IORING_POLL_ADD_MULTI	Multishot poll. Sets IORING_CQE_F_MORE if the poll handler will continue to report CQEs on behalf of the same SQE.

 * IORING_POLL_UPDATE		Update existing poll request, matching sqe.addr as the old user_data field.
 *
 * IORING_POLL_LEVEL		Level triggered poll.
 */
IORING_POLL_ADD_MULTI: u32 : (1 << 0)
IORING_POLL_UPDATE_EVENTS: u32 : (1 << 1)
IORING_POLL_UPDATE_USER_DATA: u32 : (1 << 2)
IORING_POLL_ADD_LEVEL: u32 : (1 << 3)

/*
  * send/sendmsg and recv/recvmsg flags (sq.ioprio)
  *
  * IORING_RECVSEND_POLL_FIRST	If set, instead of first attempting to send
  *				or receive and arm poll if that yields an
  *				-EAGAIN result, arm poll upfront and skip
  *				the initial transfer attempt.
  *
  * IORING_RECV_MULTISHOT	Multishot recv. Sets IORING_CQE_F_MORE if
  *				the handler will continue to report
  *				CQEs on behalf of the same SQE.
  *
  * IORING_RECVSEND_FIXED_BUF	Use registered buffers, the index is stored in
  *				the buf_index field.
  *
  * IORING_SEND_ZC_REPORT_USAGE
  *				If set, SEND[MSG]_ZC should report
  *				the zerocopy usage in cqe.res
  *				for the IORING_CQE_F_NOTIF cqe.
  *				0 is reported if zerocopy was actually possible.
  *				IORING_NOTIF_USAGE_ZC_COPIED if data was copied
  *				(at least partially).
  */
IORING_RECVSEND_POLL_FIRST: u32 : (1 << 0)
IORING_RECV_MULTISHOT: u32 : (1 << 1)
IORING_RECVSEND_FIXED_BUF: u32 : (1 << 2)
IORING_SEND_ZC_REPORT_USAGE: u32 : (1 << 3)

/*
  * cqe.res for IORING_CQE_F_NOTIF if
  * IORING_SEND_ZC_REPORT_USAGE was requested
  *
  * It should be treated as a flag, all other
  * bits of cqe.res should be treated as reserved!
  */
IORING_NOTIF_USAGE_ZC_COPIED: u32 : (1 << 31)

/*
  * accept flags stored in sq.ioprio
  */
IORING_ACCEPT_MULTISHOT: u32 : (1 << 0)

/*
  * IORING_OP_MSG_RING command types, stored in sq.addr
  */
IORING_MSG :: enum {
	DATA, /* pass sq.len as 'res' and off as user_data */
	SEND_FD, /* send a registered fd to another ring */
}

/*
  * IORING_OP_MSG_RING flags (sq.msg_ring_flags)
  *
  * IORING_MSG_RING_CQE_SKIP	Don't post a CQE to the target ring. Not
  *				applicable for IORING_MSG_DATA, obviously.
  */
IORING_MSG_RING_CQE_SKIP: u32 : (1 << 0)
/* Pass through the flags from sq.file_index to cqe.flags */
IORING_MSG_RING_FLAGS_PASS: u32 : (1 << 1)

IORING_OP :: enum u8 {
	NOP,
	READV,
	WRITEV,
	FSYNC,
	READ_FIXED,
	WRITE_FIXED,
	POLL_ADD,
	POLL_REMOVE,
	SYNC_FILE_RANGE,
	SENDMSG,
	RECVMSG,
	TIMEOUT,
	TIMEOUT_REMOVE,
	ACCEPT,
	ASYNC_CANCEL,
	LINK_TIMEOUT,
	CONNECT,
	FALLOCATE,
	OPENAT,
	CLOSE,
	FILES_UPDATE,
	STATX,
	READ,
	WRITE,
	FADVISE,
	MADVISE,
	SEND,
	RECV,
	OPENAT2,
	EPOLL_CTL,
	SPLICE,
	PROVIDE_BUFFERS,
	REMOVE_BUFFERS,
	TEE,
	SHUTDOWN,
	RENAMEAT,
	UNLINKAT,
	MKDIRAT,
	SYMLINKAT,
	LINKAT,
	/* this goes last, obviously */
	LAST,
}

/*
 * sys_io_uring_register() opcodes and arguments.
 */
IORING_REGISTER :: enum u32 {
	REGISTER_BUFFERS = 0,
	UNREGISTER_BUFFERS = 1,
	REGISTER_FILES = 2,
	UNREGISTER_FILES = 3,
	REGISTER_EVENTFD = 4,
	UNREGISTER_EVENTFD = 5,
	REGISTER_FILES_UPDATE = 6,
	REGISTER_EVENTFD_ASYNC = 7,
	REGISTER_PROBE = 8,
	REGISTER_PERSONALITY = 9,
	UNREGISTER_PERSONALITY = 10,
	REGISTER_RESTRICTIONS = 11,
	REGISTER_ENABLE_RINGS = 12,
	/* extended with tagging */
	REGISTER_FILES2 = 13,
	REGISTER_FILES_UPDATE2 = 14,
	REGISTER_BUFFERS2 = 15,
	REGISTER_BUFFERS_UPDATE = 16,
	/* set/clear io-wq thread affinities */
	REGISTER_IOWQ_AFF = 17,
	UNREGISTER_IOWQ_AFF = 18,
	/* set/get max number of io-wq workers */
	REGISTER_IOWQ_MAX_WORKERS = 19,
	/* register/unregister io_uring fd with the ring */
	REGISTER_RING_FDS = 20,
	UNREGISTER_RING_FDS = 21,
	/* register ring based provide buffer group */
	REGISTER_PBUF_RING = 22,
	UNREGISTER_PBUF_RING = 23,
	/* sync cancelation API */
	REGISTER_SYNC_CANCEL = 24,
	/* register a range of fixed file slots for automatic slot allocation */
	REGISTER_FILE_ALLOC_RANGE = 25,
	/* this goes last */
	REGISTER_LAST,
	/* flag added to the opcode to use a registered ring fd */
	REGISTER_USE_REGISTERED_RING = 1 << 31,
}

IORING_FEAT_SINGLE_MMAP: u32 : (1 << 0)
IORING_FEAT_NODROP: u32 : (1 << 1)
IORING_FEAT_SUBMIT_STABLE: u32 : (1 << 2)
IORING_FEAT_RW_CUR_POS: u32 : (1 << 3)
IORING_FEAT_CUR_PERSONALITY: u32 : (1 << 4)
IORING_FEAT_FAST_POLL: u32 : (1 << 5)
IORING_FEAT_POLL_32BITS: u32 : (1 << 6)
IORING_FEAT_SQPOLL_NONFIXED: u32 : (1 << 7)
IORING_FEAT_EXT_ARG: u32 : (1 << 8)
IORING_FEAT_NATIVE_WORKERS: u32 : (1 << 9)
IORING_FEAT_RSRC_TAGS: u32 : (1 << 10)

/*
 * cqe.flags
 *
 * IORING_CQE_F_BUFFER	If set, the upper 16 bits are the buffer ID
 * IORING_CQE_F_MORE	If set, parent SQE will generate more CQE entries
 * IORING_CQE_F_SOCK_NONEMPTY	If set, more data to read after socket recv
 * IORING_CQE_F_NOTIF	Set for notification CQEs. Can be used to distinct
 * 			them from sends.
 */
IORING_CQE_F_BUFFER: u32 : (1 << 0)
IORING_CQE_F_MORE: u32 : (1 << 1)
IORING_CQE_F_SOCK_NONEMPTY: u32 : (1 << 2)
IORING_CQE_F_NOTIF: u32 : (1 << 3)

IORING_CQE :: enum {
	BUFFER_SHIFT = 16,
}

/*
 * cq_ring->flags
 */
// disable eventfd notifications
IORING_CQ_EVENTFD_DISABLED: u32 : (1 << 0)

/*
 * io_uring_enter(2) flags
 */
IORING_ENTER_GETEVENTS: u32 : (1 << 0)
IORING_ENTER_SQ_WAKEUP: u32 : (1 << 1)
IORING_ENTER_SQ_WAIT: u32 : (1 << 2)
IORING_ENTER_EXT_ARG: u32 : (1 << 3)
IORING_ENTER_REGISTERED_RING: u32 : (1 << 4)

/*
 * Magic offsets for the application to mmap the data it needs
 */
IORING_OFF_SQ_RING: uintptr : 0
IORING_OFF_CQ_RING: u64 : 0x8000000
IORING_OFF_SQES: uintptr : 0x10000000
IORING_OFF_PBUF_RING: u64 : 0x80000000
IORING_OFF_PBUF_SHIFT :: 16
IORING_OFF_MMAP_MASK: u64 : 0xf8000000

sys_io_uring_setup :: proc "contextless" (entries: u32, params: ^io_uring_params) -> int {
	return int(intrinsics.syscall(SYS_io_uring_setup, uintptr(entries), uintptr(params)))
}

sys_io_uring_enter :: proc "contextless" (
	fd: u32,
	to_submit: u32,
	min_complete: u32,
	flags: u32,
	sig: ^sigset_t,
) -> int {
	return int(
		intrinsics.syscall(
			SYS_io_uring_enter,
			uintptr(fd),
			uintptr(to_submit),
			uintptr(min_complete),
			uintptr(flags),
			uintptr(sig),
			NSIG / 8 if sig != nil else 0,
		),
	)
}

sys_io_uring_register :: proc "contextless" (fd: u32, opcode: IORING_REGISTER, arg: rawptr, nr_args: u32) -> int {
	return int(intrinsics.syscall(SYS_io_uring_register, uintptr(fd), uintptr(opcode), uintptr(arg), uintptr(nr_args)))
}
