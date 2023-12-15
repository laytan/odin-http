package http

import "core:fmt"
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
	Use_Proxy                       = 305, // Deprecated.
	Unused                          = 306, // Deprecated.
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
	for field in Status {
		name, ok := fmt.enum_value_to_string(field)
		assert(ok)

		b: strings.Builder
		strings.write_int(&b, int(field))
		strings.write_byte(&b, ' ')

		// Some edge cases aside, replaces underscores in the enum name with spaces.
		#partial switch field {
		case .Non_Authoritative_Information: strings.write_string(&b, "Non-Authoritative Information")
		case .Multi_Status:                  strings.write_string(&b, "Multi-Status")
		case .Im_A_Teapot:                   strings.write_string(&b, "I'm a teapot")
		case:
			for c in name {
				switch c {
				case '_': strings.write_rune(&b, ' ')
				case:     strings.write_rune(&b, c)
				}
			}
		}

		_status_strings[field] = strings.to_string(b)
	}
}

status_string :: proc(s: Status) -> string {
	if s >= Status(0) && s <= max(Status) {
		return _status_strings[s]
	}

	return ""
}

status_valid :: proc(s: Status) -> bool {
	return status_string(s) != ""
}

status_from_string :: proc(s: string) -> (Status, bool) {
	if len(s) < 3 do return {}, false

	code_int := int(s[0]-'0')*100 + (int(s[1]-'0')*10) + int(s[2]-'0')

	if !status_valid(Status(code_int)) {
		return {}, false
	}

	return Status(code_int), true
}

status_is_informational :: proc(s: Status) -> bool {
	return s >= Status(100) && s < Status(200)
}

status_is_success :: proc(s: Status) -> bool {
	return s >= Status(200) && s < Status(300)
}

status_is_redirect :: proc(s: Status) -> bool {
	return s >= Status(300) && s < Status(400)
}

status_is_client_error :: proc(s: Status) -> bool {
	return s >= Status(400) && s < Status(500)
}

status_is_server_error :: proc(s: Status) -> bool {
	return s >= Status(500) && s < Status(600)
}
