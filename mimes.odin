package http

import "core:path/filepath"

Mime_Type :: enum {
	Plain,
	Json,
	Ico,
	Html,
}

mime_from_extension :: proc(s: string) -> Mime_Type {
	switch filepath.ext(s) {
	case ".json":
		return .Json
	case ".ico":
		return .Ico
	case ".html":
		return .Html
	case:
		return .Plain
	}
}

mime_to_content_type :: proc(m: Mime_Type) -> string {
	switch m {
	case .Html:
		return "text/html"
	case .Ico:
		return "application/vnd.microsoft.ico"
	case .Json:
		return "application/json"
	case .Plain:
		return "text/plain"
	case:
		return "text/plain"
	}
}
