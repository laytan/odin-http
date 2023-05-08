package http

Status :: enum {
	Continue                      = 100,
	SwitchingProtocols            = 101,
	Processing                    = 102,
	EarlyHints                    = 103,

	Ok                            = 200,
	Created                       = 201,
	Accepted                      = 202,
	NonAuthoritativeInformation   = 203,
	NoContent                     = 204,
	ResetContent                  = 205,
	PartialContent                = 206,
	MultiStatus                   = 207,
	AlreadyReported               = 208,
	ImUsed                        = 226,

	MultipleChoices               = 300,
	MovedPermanently              = 301,
	Found                         = 302,
	SeeOther                      = 303,
	NotModified                   = 304,
	TemporaryRedirect             = 307,
	PermanentRedirect             = 308,

	BadRequest                    = 400,
	Unauthorized                  = 401,
	PaymentRequired               = 402,
	Forbidden                     = 403,
	NotFound                      = 404,
	MethodNotAllowed              = 405,
	NotAcceptable                 = 406,
	ProxyAuthenticationRequired   = 407,
	RequestTimeout                = 408,
	Conflict                      = 409,
	Gone                          = 410,
	LengthRequired                = 411,
	PreconditionFailed            = 412,
	PayloadTooLarge               = 413,
	UriTooLong                    = 414,
	UnsupportedMediaType          = 415,
	RangeNotSatisfiable           = 416,
	ExpectationFailed             = 417,
	ImATeapot                     = 418,
	MisdirectedRequest            = 421,
	UnprocessableContent          = 422,
	Locked                        = 423,
	FailedDependency              = 424,
	TooEarly                      = 425,
	UpgradeRequired               = 426,
	PreconditionRequired          = 428,
	TooManyRequests               = 429,
	RequestHeaderFieldsTooLarge   = 431,
	UnavailableForLegalReasons    = 451,

	InternalServerError           = 500,
	NotImplemented                = 501,
	BadGateway                    = 502,
	ServiceUnavailable            = 503,
	GatewayTimeout                = 504,
	HttpVersionNotSupported       = 505,
	VariantAlsoNegotiates         = 506,
	InsufficientStorage           = 507,
	LoopDetected                  = 508,
	NotExtended                   = 510,
	NetworkAuthenticationRequired = 511,
}

status_string :: proc(s: Status) -> string {
	switch s {
	case .Continue:                      return "100 Continue"
	case .SwitchingProtocols:            return "101 Switching Protocols"
	case .Processing:                    return "102 Processing"
	case .EarlyHints:                    return "103 Early Hints"
	case .Ok:                            return "200 OK"
	case .Created:                       return "201 Created"
	case .Accepted:                      return "202 Accepted"
	case .NonAuthoritativeInformation:   return "203 Non-Authoritative Information"
	case .NoContent:                     return "204 No Content"
	case .ResetContent:                  return "205 Reset Content"
	case .PartialContent:                return "206 Partial Content"
	case .MultiStatus:                   return "207 Multi-Status"
	case .AlreadyReported:               return "208 Already Reported"
	case .ImUsed:                        return "226 IM Used"
	case .MultipleChoices:               return "300 Multiple Choices"
	case .MovedPermanently:              return "301 Moved Permanently"
	case .Found:                         return "302 Found"
	case .SeeOther:                      return "303 See Other"
	case .NotModified:                   return "304 Not Modified"
	case .TemporaryRedirect:             return "307 Temporary Redirect"
	case .PermanentRedirect:             return "308 Permanent Redirect"
	case .BadRequest:                    return "400 Bad Request"
	case .Unauthorized:                  return "401 Unauthorized"
	case .PaymentRequired:               return "402 Payment Required"
	case .Forbidden:                     return "403 Forbidden"
	case .NotFound:                      return "404 Not Found"
	case .MethodNotAllowed:              return "405 Method Not Allowed"
	case .NotAcceptable:                 return "406 Not Acceptable"
	case .ProxyAuthenticationRequired:   return "407 Proxy Authentication Required"
	case .RequestTimeout:                return "408 Request Timeout"
	case .Conflict:                      return "409 Conflict"
	case .Gone:                          return "410 Gone"
	case .LengthRequired:                return "411 Length Required"
	case .PreconditionFailed:            return "412 Precondition Required"
	case .PayloadTooLarge:               return "413 Payload Too Large"
	case .UriTooLong:                    return "414 URI Too Long"
	case .UnsupportedMediaType:          return "415 Unsupported Media Type"
	case .RangeNotSatisfiable:           return "416 Range Not Satisfiable"
	case .ExpectationFailed:             return "417 Expectation Failed"
	case .ImATeapot:                     return "418 I'm a teapot"
	case .MisdirectedRequest:            return "421 Misdirected Request"
	case .UnprocessableContent:          return "422 Unprocessable Content"
	case .Locked:                        return "423 Locked"
	case .FailedDependency:              return "424 Failed Dependency"
	case .TooEarly:                      return "425 Too Early"
	case .UpgradeRequired:               return "426 Upgrade Required"
	case .PreconditionRequired:          return "428 Precondition Required"
	case .TooManyRequests:               return "429 Too Many Requests"
	case .RequestHeaderFieldsTooLarge:   return "431 Request Header Fields Too Large"
	case .UnavailableForLegalReasons:    return "451 Unavailable For Legal Reasons"
	case .InternalServerError:           return "500 Internal Server Error"
	case .NotImplemented:                return "501 Not Implemented"
	case .BadGateway:                    return "502 Bad Gateway"
	case .ServiceUnavailable:            return "503 Service Unavailable"
	case .GatewayTimeout:                return "504 Gateway Timeout"
	case .HttpVersionNotSupported:       return "505 HTTP Version Not Supported"
	case .VariantAlsoNegotiates:         return "506 Variant Also Negotiates"
	case .InsufficientStorage:           return "507 Insufficient Storage"
	case .LoopDetected:                  return "508 Loop Detected"
	case .NotExtended:                   return "510 Not Extended"
	case .NetworkAuthenticationRequired: return "511 Network Authentication Required"
	case:                                return ""
	}
}

status_informational :: proc(s: Status) -> bool {
    return s < .Ok
}

status_success :: proc(s: Status) -> bool {
    return s >= .Ok && s < .MultipleChoices
}

status_redirect :: proc(s: Status) -> bool {
	return s >= .MultipleChoices && s < .BadRequest
}

status_client_error :: proc(s: Status) -> bool {
	return s >= .BadRequest && s < .InternalServerError
}

status_server_error :: proc(s: Status) -> bool {
	return s >= .InternalServerError
}
