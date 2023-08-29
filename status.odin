package http

Status :: enum {
	NotFound                        = 404,
	Continue                        = 100,
	Switching_Protocols             = 101,
	Processing                      = 102,
	Early_Hints                     = 103,

	Ok                              = 200,
	Created                         = 201,
	Accepted                        = 202,
	Non_Authoritative_Information   = 203,
	No_Content                      = 204,
	Reset_Content                   = 205,
	Partial_Content                 = 206,
	Multi_Status                    = 207,
	Already_Reported                = 208,
	Im_Used                         = 226,

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
	// NotFound is first in this enum (default).
	// NotFound                     = 404,
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
	TooEarly                        = 425,
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

status_string :: proc(s: Status) -> string {
	switch s {
	case .Continue:                        return "100 Continue"
	case .Switching_Protocols:             return "101 Switching Protocols"
	case .Processing:                      return "102 Processing"
	case .Early_Hints:                     return "103 Early Hints"
	case .Ok:                              return "200 OK"
	case .Created:                         return "201 Created"
	case .Accepted:                        return "202 Accepted"
	case .Non_Authoritative_Information:   return "203 Non-Authoritative Information"
	case .No_Content:                      return "204 No Content"
	case .Reset_Content:                   return "205 Reset Content"
	case .Partial_Content:                 return "206 Partial Content"
	case .Multi_Status:                    return "207 Multi-Status"
	case .Already_Reported:                return "208 Already Reported"
	case .Im_Used:                         return "226 IM Used"
	case .Multiple_Choices:                return "300 Multiple Choices"
	case .Moved_Permanently:               return "301 Moved Permanently"
	case .Found:                           return "302 Found"
	case .See_Other:                       return "303 See Other"
	case .Not_Modified:                    return "304 Not Modified"
	case .Temporary_Redirect:              return "307 Temporary Redirect"
	case .Permanent_Redirect:              return "308 Permanent Redirect"
	case .Bad_Request:                     return "400 Bad Request"
	case .Unauthorized:                    return "401 Unauthorized"
	case .Payment_Required:                return "402 Payment Required"
	case .Forbidden:                       return "403 Forbidden"
	case .NotFound:                        return "404 Not Found"
	case .Method_Not_Allowed:              return "405 Method Not Allowed"
	case .Not_Acceptable:                  return "406 Not Acceptable"
	case .Proxy_Authentication_Required:   return "407 Proxy Authentication Required"
	case .Request_Timeout:                 return "408 Request Timeout"
	case .Conflict:                        return "409 Conflict"
	case .Gone:                            return "410 Gone"
	case .Length_Required:                 return "411 Length Required"
	case .Precondition_Failed:             return "412 Precondition Required"
	case .Payload_Too_Large:               return "413 Payload Too Large"
	case .URI_Too_Long:                    return "414 URI Too Long"
	case .Unsupported_Media_Type:          return "415 Unsupported Media Type"
	case .Range_Not_Satisfiable:           return "416 Range Not Satisfiable"
	case .Expectation_Failed:              return "417 Expectation Failed"
	case .Im_A_Teapot:                     return "418 I'm a teapot"
	case .Misdirected_Request:             return "421 Misdirected Request"
	case .Unprocessable_Content:           return "422 Unprocessable Content"
	case .Locked:                          return "423 Locked"
	case .Failed_Dependency:               return "424 Failed Dependency"
	case .TooEarly:                        return "425 Too Early"
	case .Upgrade_Required:                return "426 Upgrade Required"
	case .Precondition_Required:           return "428 Precondition Required"
	case .Too_Many_Requests:               return "429 Too Many Requests"
	case .Request_Header_Fields_Too_Large: return "431 Request Header Fields Too Large"
	case .Unavailable_For_Legal_Reasons:   return "451 Unavailable For Legal Reasons"
	case .Internal_Server_Error:           return "500 Internal Server Error"
	case .Not_Implemented:                 return "501 Not Implemented"
	case .Bad_Gateway:                     return "502 Bad Gateway"
	case .Service_Unavailable:             return "503 Service Unavailable"
	case .Gateway_Timeout:                 return "504 Gateway Timeout"
	case .HTTP_Version_Not_Supported:      return "505 HTTP Version Not Supported"
	case .Variant_Also_Negotiates:         return "506 Variant Also Negotiates"
	case .Insufficient_Storage:            return "507 Insufficient Storage"
	case .Loop_Detected:                   return "508 Loop Detected"
	case .Not_Extended:                    return "510 Not Extended"
	case .Network_Authentication_Required: return "511 Network Authentication Required"
	case:                                  return ""
	}
}

status_from_string :: proc(s: string) -> (Status, bool) {
	for status in Status {
		ss := status_string(status)
		if s[:3] == ss[:3] {
			return status, true
		}
	}

	return .Method_Not_Allowed, false
}

status_informational :: proc(s: Status) -> bool {
	return s < .Ok
}

status_success :: proc(s: Status) -> bool {
	return s >= .Ok && s < .Multiple_Choices
}

status_redirect :: proc(s: Status) -> bool {
	return s >= .Multiple_Choices && s < .Bad_Request
}

status_client_error :: proc(s: Status) -> bool {
	return s >= .Bad_Request && s < .Internal_Server_Error
}

status_server_error :: proc(s: Status) -> bool {
	return s >= .Internal_Server_Error
}
