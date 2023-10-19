package http

import "core:fmt"
import "core:reflect"
import "core:strings"

Status :: enum {
	Continue                        = 100,
	Switching_Protocols             = 101,
	Processing                      = 102,
	Early_Hints                     = 103,
	OK                              = 200,
	Created                         = 201,
	Accepted                        = 202,
	Non_Authoritative_Information   = 203,
	No_Content                      = 204,
	Reset_Content                   = 205,
	Partial_Content                 = 206,
	Multi_Status                    = 207,
	Already_Reported                = 208,
	IM_Used                         = 226,
	Multiple_Choices                = 300,
	Moved_Permanently               = 301,
	Found                           = 302,
	See_Other                       = 303,
	Not_Modified                    = 304,
	Temporary_Redirect              = 307,
	Permanent_Redirect              = 308,
	Bad_Request                     = 400,
	Unauthorized                    = 401,
	Payment_Required                = 402,
	Forbidden                       = 403,
	Not_Found                       = 404,
	Method_Not_Allowed              = 405,
	Not_Acceptable                  = 406,
	Proxy_Authentication_Required   = 407,
	Request_Timeout                 = 408,
	Conflict                        = 409,
	Gone                            = 410,
	Length_Required                 = 411,
	Precondition_Failed             = 412,
	Payload_Too_Large               = 413,
	URI_Too_Long                    = 414,
	Unsupported_Media_Type          = 415,
	Range_Not_Satisfiable           = 416,
	Expectation_Failed              = 417,
	Im_A_Teapot                     = 418,
	Misdirected_Request             = 421,
	Unprocessable_Content           = 422,
	Locked                          = 423,
	Failed_Dependency               = 424,
	Too_Early                       = 425,
	Upgrade_Required                = 426,
	Precondition_Required           = 428,
	Too_Many_Requests               = 429,
	Request_Header_Fields_Too_Large = 431,
	Unavailable_For_Legal_Reasons   = 451,
	Internal_Server_Error           = 500,
	Not_Implemented                 = 501,
	Bad_Gateway                     = 502,
	Service_Unavailable             = 503,
	Gateway_Timeout                 = 504,
	HTTP_Version_Not_Supported      = 505,
	Variant_Also_Negotiates         = 506,
	Insufficient_Storage            = 507,
	Loop_Detected                   = 508,
	Not_Extended                    = 510,
	Network_Authentication_Required = 511,
}

_status_strings: [max(Status) + Status(1)]string

// Populates the status_strings like a map from status to their string representation.
// Where an empty string means an invalid code.
@(init, private)
status_strings_init :: proc() {
	// Some edge cases aside, replaces underscores in the enum name with spaces.
	status_name_fmt :: proc(val: Status, orig: string) -> (new: string, allocated: bool) {
		#partial switch val {
		case .Non_Authoritative_Information:
			return "Non-Authoritative Information", false
		case .Multi_Status:
			return "Multi-Status", false
		case .Im_A_Teapot:
			return "I'm a teapot", false
		case:
			return strings.replace_all(orig, "_", " ")
		}
	}

	fields := reflect.enum_fields_zipped(Status)
	for field in fields {
		fmted, allocated := status_name_fmt(Status(field.value), field.name)
		defer if allocated do delete(fmted)

		_status_strings[field.value] = fmt.aprintf("%i %s", field.value, fmted)
	}
}

status_string :: #force_inline proc(s: Status) -> string {
	return _status_strings[s] if s <= .Network_Authentication_Required else ""
}

status_valid :: #force_inline proc(s: Status) -> bool {
	return s >= Status(0) && s <= .Network_Authentication_Required && _status_strings[s] != ""
}

status_from_string :: proc(s: string) -> (Status, bool) {
	if len(s) < 3 do return {}, false

	// Turns the string of length 3 into an int.
	// It goes from right to left, increasing a multiplier (for base 10).
	// Say we got status "123"
	// i == 0, b == "3", (b - '0') == 3, code_int += 3 * 1
	// i == 1, b == "2", (b - '0') == 2, code_int += 2 * 10
	// i == 2, b == "1", (b - '0') == 1, code_int += 1 * 100

	code := s[:3]
	code_int: int
	multiplier := 1
	for i in 0 ..< len(code) {
		b := code[2 - i]
		code_int += int(b - '0') * multiplier
		multiplier *= 10
	}

	if !status_valid(Status(code_int)) {
		return {}, false
	}

	return Status(code_int), true
}

status_is_informational :: proc(s: Status) -> bool {
	return s < .OK
}

status_is_success :: proc(s: Status) -> bool {
	return s >= .OK && s < .Multiple_Choices
}

status_is_redirect :: proc(s: Status) -> bool {
	return s >= .Multiple_Choices && s < .Bad_Request
}

status_is_client_error :: proc(s: Status) -> bool {
	return s >= .Bad_Request && s < .Internal_Server_Error
}

status_is_server_error :: proc(s: Status) -> bool {
	return s >= .Internal_Server_Error
}
