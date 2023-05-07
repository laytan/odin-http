package http

import "core:strings"
import "core:path/filepath"

MimeType :: enum {
	Plain,
	Json,
	Ico,
	Html,
}

mime_from_extension :: proc(s: string) -> MimeType {
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

mime_to_content_type :: proc(m: MimeType) -> string {
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
