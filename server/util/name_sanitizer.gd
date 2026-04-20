class_name NameSanitizer

const MAX_LEN: int = 12

static func sanitize(raw: String, pid: int) -> String:
	var s := raw.strip_edges()
	var clean := ""
	for c in s:
		var code := c.unicode_at(0)
		if code >= 0x20 and code <= 0x7E:
			clean += c
	if clean.length() > MAX_LEN:
		clean = clean.substr(0, MAX_LEN)
	if clean.is_empty():
		return "P" + str(pid)
	return clean
