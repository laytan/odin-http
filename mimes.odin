package http

import "core:path/filepath"

Mime_Type :: enum {
	Plain,
	Json,
	Ico,
	Html,
	Js,
	Css,
}

mime_from_extension :: proc(s: string) -> Mime_Type {
	//odinfmt:disable
	switch filepath.ext(s) {
	case ".json": return .Json
	case ".ico":  return .Ico
	case ".html": return .Html
	case ".css":  return .Css
	case ".js":   return .Js
	case:         return .Plain
	}
	//odinfmt:enable
}

mime_to_content_type :: proc(m: Mime_Type) -> string {
	//odinfmt:disable
	switch m {
	case .Html:  return "text/html"
	case .Ico:   return "application/vnd.microsoft.ico"
	case .Json:  return "application/json"
	case .Plain: return "text/plain"
	case .Css:   return "text/css"
	case .Js:    return "application/javascript"
	case:        return "text/plain"
	}
	//odinfmt:enable
}
