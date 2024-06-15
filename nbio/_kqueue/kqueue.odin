//+build darwin, openbsd, freebsd
package kqueue

when ODIN_OS == .Darwin {
	foreign import lib "system:System.framework"
} else {
	foreign import lib "system:c"
}

import "core:c"
import "core:os"

Queue_Error :: enum {
	None,
	Out_Of_Memory         = int(os.ENOMEM),
	Descriptor_Table_Full = int(os.EMFILE),
	File_Table_Full       = int(os.ENFILE),
}

kqueue :: proc() -> (kq: os.Handle, err: Queue_Error) {
	kq = os.Handle(_kqueue())
	if kq == -1 {
		err = Queue_Error(os.get_last_error())
	}
	return
}

Event_Error :: enum {
	None,
	Access_Denied             = int(os.EACCES),
	Invalid_Event             = int(os.EFAULT),
	Invalid_Descriptor        = int(os.EBADF),
	Signal                    = int(os.EINTR),
	Invalid_Timeout_Or_Filter = int(os.EINVAL),
	Event_Not_Found           = int(os.ENOENT),
	Out_Of_Memory             = int(os.ENOMEM),
	Process_Not_Found         = int(os.ESRCH),
}

kevent :: proc(
	kq: os.Handle,
	change_list: []KEvent,
	event_list: []KEvent,
	timeout: ^os.Unix_File_Time,
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
		err = Event_Error(os.get_last_error())
	}
	return
}

KEvent :: struct {
	// Value used to identify this event.  The exact interpretation
	// is determined by the attached filter, but often is a file
	// descriptor.
	ident:  uintptr,
	filter: Filter,
	// Actions to perform on the event.
	flags:  Flags,
	// Filter specific flags.
	fflags: struct #raw_union {
		read:   RW_Flags,
		write:  RW_Flags,
		vnode:  VNode_Flags,
		fproc:   u32, // TODO: weird flag values.
	},
	// Filter specific data.
	// read:  on connected sockets this is the listen backlog, otherwise the amount of bytes.
	// write: the amount of bytes ready to write without blocking.
	// vnode: nothing.
	// proc:  nothing.
	data:   int,
	// Opaque user data passed through the kernel unchanged.
	udata:  rawptr,
}

Flag :: enum {
	Add,            // Add event to kq (implies .Enable).
	Delete,         // Delete event from kq.
	Enable,         // Enable event.
	Disable,        // Disable event (not reported).
	One_Shot,       // Only report one occurrence.
	Clear,          // Clear event state after reporting.
	Dispatch,       // Disable event after reporting.
	Udata_Specific, // Unique event per udata value.
	Fanished,       // Report that source has vanished.
	Sys_Flags,      // Reserved by system.
	Flag0,          // Filter-specific flag.
	Flag1,          // Filter-specific flag.
	Error,          // Error, data contains errno.
	EOF,            // EOF detected.
}

Flags :: bit_set[Flag; u16]

DISPATCH_2 :: Flags{ .Dispatch, .Udata_Specific }

Filter :: enum i16 {
	// Check for read availability on the file descriptor.
	Read      = -1,
	// Check for write availability on the file descriptor.
	Write     = -2,
	// AIO       = -3,
	// Check for changes to the subject file.
	VNode     = -4,
	// Check for changes to the subject process.
	Proc      = -5,
	// Check for signals delivered to the process.
	Signal    = -6,
	// Timer     = -7,
	// Mach_Port = -8,
	// FS        = -9,
	// User      = -10,
	// VM        = -12,
	// Except    = -15,
}

RW_Flag :: enum {
	Low_Water_Mark,
	Out_Of_Bounds,
}
RW_Flags :: bit_set[RW_Flag; u32]

VNode_Flag :: enum {
	Delete, // Deleted.
	Write,  // Contents changed.
	Extend, // Size increased.
	Attrib, // Attributes changed.
	Link,   // Link count changed.
	Rename, // Renamed.
	Revoke, // Access was revoked.
}
VNode_Flags :: bit_set[VNode_Flag; u32]

@(private)
foreign lib {
	@(link_name = "kqueue")
	_kqueue :: proc() -> c.int ---
	@(link_name = "kevent")
	_kevent :: proc(kq: c.int, change_list: [^]KEvent, n_changes: c.int, event_list: [^]KEvent, n_events: c.int, timeout: ^os.Unix_File_Time) -> c.int ---
}
