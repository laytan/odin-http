//+build darwin
package kqueue

import "core:c"
import "core:os"

Queue_Error :: enum {
	None,
	Out_Of_Memory,
	Descriptor_Table_Full,
	File_Table_Full,
	Unknown,
}

kqueue :: proc() -> (kq: os.Handle, err: Queue_Error) {
	kq = os.Handle(_kqueue())
	if kq == -1 {
		switch os.Errno(os.get_last_error()) {
		case os.ENOMEM:
			err = .Out_Of_Memory
		case os.EMFILE:
			err = .Descriptor_Table_Full
		case os.ENFILE:
			err = .File_Table_Full
		case:
			err = .Unknown
		}
	}
	return
}

Event_Error :: enum {
	None,
	Access_Denied,
	Invalid_Event,
	Invalid_Descriptor,
	Signal,
	Invalid_Timeout_Or_Filter,
	Event_Not_Found,
	Out_Of_Memory,
	Process_Not_Found,
	Unknown,
}

kevent :: proc(
	kq: os.Handle,
	change_list: []KEvent,
	event_list: []KEvent,
	timeout: ^Time_Spec,
) -> (
	n_events: int,
	err: Event_Error,
) {
	n_events = int(
		_kevent(
			c.int(kq),
			raw_data(change_list),
			c.int(len(change_list)),
			raw_data(event_list),
			c.int(len(event_list)),
			timeout,
		),
	)
	if n_events == -1 {
		switch os.Errno(os.get_last_error()) {
		case os.EACCES:
			err = .Access_Denied
		case os.EFAULT:
			err = .Invalid_Event
		case os.EBADF:
			err = .Invalid_Descriptor
		case os.EINTR:
			err = .Signal
		case os.EINVAL:
			err = .Invalid_Timeout_Or_Filter
		case os.ENOENT:
			err = .Event_Not_Found
		case os.ENOMEM:
			err = .Out_Of_Memory
		case os.ESRCH:
			err = .Process_Not_Found
		case:
			err = .Unknown
		}
	}
	return
}

KEvent :: struct {
	ident:  c.uintptr_t,
	filter: c.int16_t,
	flags:  c.uint16_t,
	fflags: c.uint32_t,
	data:   c.intptr_t,
	udata:  rawptr,
}

Time_Spec :: struct {
	sec:  c.long,
	nsec: c.long,
}

EV_ADD :: 0x0001 /* add event to kq (implies enable) */
EV_DELETE :: 0x0002 /* delete event from kq */
EV_ENABLE :: 0x0004 /* enable event */
EV_DISABLE :: 0x0008 /* disable event (not reported) */
EV_ONESHOT :: 0x0010 /* only report one occurrence */
EV_CLEAR :: 0x0020 /* clear event state after reporting */
EV_RECEIPT :: 0x0040 /* force immediate event output */
EV_DISPATCH :: 0x0080 /* disable event after reporting */
EV_UDATA_SPECIFIC :: 0x0100 /* unique kevent per udata value */
EV_FANISHED :: 0x0200 /* report that source has vanished  */
EV_SYSFLAGS :: 0xF000 /* reserved by system */
EV_FLAG0 :: 0x1000 /* filter-specific flag */
EV_FLAG1 :: 0x2000 /* filter-specific flag */
EV_ERROR :: 0x4000 /* error, data contains errno */
EV_EOF :: 0x8000 /* EOF detected */
EV_DISPATCH2 :: (EV_DISPATCH | EV_UDATA_SPECIFIC)

EVFILT_READ :: -1
EVFILT_WRITE :: -2
EVFILT_AIO :: -3
EVFILT_VNODE :: -4
EVFILT_PROC :: -5
EVFILT_SIGNAL :: -6
EVFILT_TIMER :: -7
EVFILT_MACHPORT :: -8
EVFILT_FS :: -9
EVFILT_USER :: -10
EVFILT_VM :: -12
EVFILT_EXCEPT :: -15

@(default_calling_convention = "c")
foreign _ {
	@(link_name = "kqueue")
	_kqueue :: proc() -> c.int ---
	@(link_name = "kevent")
	_kevent :: proc(kq: c.int, change_list: [^]KEvent, n_changes: c.int, event_list: [^]KEvent, n_events: c.int, timeout: ^Time_Spec) -> c.int ---
}
