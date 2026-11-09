@tool
extends RefCounted
## Markdown -> BBCode for RichTextLabel, safe by construction: every character of the input is either
## escaped or part of a tag emitted here, so a reply (or tool output) can never inject [img], [url],
## [font] ... of its own. Unfinished markdown (streaming) stays readable: an unclosed ** or ``` is
## treated as plain text / a code block that has not ended yet.

const TextLinks = preload("../ui/text_links.gd")

const CODE_BG := "#00000055"
const INLINE_BG := "#ffffff1f"
const QUOTE_COLOR := "#9aa3ad"
const HEADING_SIZES := [0, 22, 19, 17, 16, 15, 15]


## "[" is the only character that can open a tag.
static func escape(text: String) -> String:
	return text.replace("[", "[lb]")


static func to_bbcode(markdown: String) -> String:
	var lines := markdown.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var out := PackedStringArray()
	var code_lines := PackedStringArray()
	var in_code := false
	var i := 0
	while i < lines.size():
		var line: String = lines[i]
		var stripped := line.strip_edges(true, false)

		if stripped.begins_with("```"):
			if in_code:
				out.append(code_block(code_lines))
				code_lines = PackedStringArray()
			in_code = not in_code
			i += 1
			continue
		if in_code:
			code_lines.append(line)
			i += 1
			continue

		# Table: a row of |cells| followed by a |---|---| separator row.
		if stripped.begins_with("|") and i + 1 < lines.size() and _is_table_separator(lines[i + 1]):
			var rows := [_cells(stripped)]
			i += 2
			while i < lines.size() and lines[i].strip_edges().begins_with("|"):
				rows.append(_cells(lines[i].strip_edges()))
				i += 1
			out.append(_table(rows))
			continue

		out.append(_block_line(line, stripped))
		i += 1

	if in_code:
		out.append(code_block(code_lines))  # still streaming: show what we have
	return "\n".join(out)


static func code_block(code_lines: PackedStringArray) -> String:
	return "[bgcolor=%s][code]%s[/code][/bgcolor]" % [CODE_BG, escape("\n".join(code_lines))]


static func _block_line(line: String, stripped: String) -> String:
	if stripped.is_empty():
		return ""
	# Heading
	if stripped.begins_with("#"):
		var level := 0
		while level < stripped.length() and stripped[level] == "#":
			level += 1
		if level <= 6 and stripped.length() > level and stripped[level] == " ":
			return "[font_size=%d][b]%s[/b][/font_size]" % [HEADING_SIZES[level], inline(stripped.substr(level + 1).strip_edges())]
	# Horizontal rule
	if stripped.length() >= 3 and (stripped.count("-") == stripped.length() or stripped.count("*") == stripped.length() or stripped.count("_") == stripped.length()):
		return "[color=%s]────────────[/color]" % QUOTE_COLOR
	# Quote
	if stripped.begins_with(">"):
		return "[color=%s]▎ %s[/color]" % [QUOTE_COLOR, inline(stripped.substr(1).strip_edges())]
	# Bullet list (two spaces of indentation per level)
	var indent := line.length() - line.strip_edges(true, false).length()
	var depth := mini(indent / 2, 4)
	for marker in ["- ", "* ", "+ "]:
		if stripped.begins_with(marker):
			return "[indent]".repeat(depth) + "• " + inline(stripped.substr(2)) + "[/indent]".repeat(depth)
	# Numbered list
	var dot := stripped.find(". ")
	if dot > 0 and dot <= 3 and stripped.left(dot).is_valid_int():
		return "[indent]".repeat(depth) + escape(stripped.left(dot + 1)) + " " + inline(stripped.substr(dot + 2)) + "[/indent]".repeat(depth)
	return inline(line)


static func _is_table_separator(line: String) -> bool:
	var s := line.strip_edges()
	if not s.begins_with("|") or not s.contains("-"):
		return false
	for ch in s:
		if not ch in ["|", "-", ":", " "]:
			return false
	return true


static func _cells(row: String) -> Array:
	var parts := row.trim_prefix("|").trim_suffix("|").split("|")
	var cells := []
	for part in parts:
		cells.append(part.strip_edges())
	return cells


static func _table(rows: Array) -> String:
	var columns := 0
	for row in rows:
		columns = maxi(columns, row.size())
	var out := "[table=%d]" % columns
	for r in rows.size():
		for c in columns:
			var cell: String = rows[r][c] if c < rows[r].size() else ""
			var body := inline(cell)
			out += "[cell]%s[/cell]" % (("[b]%s[/b]" % body) if r == 0 else body)
	return out + "[/table]"


## Inline markdown: `code`, **bold**, *italic*, [text](url), bare URLs and res:// paths.
static func inline(text: String) -> String:
	var out := ""
	var plain := ""
	var i := 0
	var n := text.length()
	while i < n:
		var c := text[i]
		if c == "`":
			var j := text.find("`", i + 1)
			if j > i + 1:
				out += _plain(plain) + "[bgcolor=%s][code]%s[/code][/bgcolor]" % [INLINE_BG, escape(text.substr(i + 1, j - i - 1))]
				plain = ""
				i = j + 1
				continue
		elif c == "*" and text.substr(i, 2) == "**":
			var j := text.find("**", i + 2)
			if j > i + 2:
				out += _plain(plain) + "[b]" + inline(text.substr(i + 2, j - i - 2)) + "[/b]"
				plain = ""
				i = j + 2
				continue
		elif (c == "*" or c == "_") and i + 1 < n and text[i + 1] != " " and (c == "*" or _word_boundary(text, i - 1)):
			var j := text.find(c, i + 1)
			if j > i + 1 and text[j - 1] != " " and (c == "*" or _word_boundary(text, j + 1)):
				out += _plain(plain) + "[i]" + inline(text.substr(i + 1, j - i - 1)) + "[/i]"
				plain = ""
				i = j + 1
				continue
		elif c == "[":
			var mid := text.find("](", i + 1)
			var end := text.find(")", mid + 2) if mid > i else -1
			if mid > i and end > mid:
				var url := text.substr(mid + 2, end - mid - 2)
				if _is_safe_url(url):
					out += _plain(plain) + "[url=%s]%s[/url]" % [url, inline(text.substr(i + 1, mid - i - 1))]
					plain = ""
					i = end + 1
					continue
		plain += c
		i += 1
	return out + _plain(plain)


## True when the character at `index` (or the text edge) is not a letter/digit.
static func _word_boundary(text: String, index: int) -> bool:
	if index < 0 or index >= text.length():
		return true
	var ch := text[index]
	return not (ch == "_" or ch.to_lower() != ch.to_upper() or ch.is_valid_int())


static func _is_safe_url(url: String) -> bool:
	if not (url.begins_with("http://") or url.begins_with("https://") or url.begins_with("res://")):
		return false
	for ch in ["[", "]", "\"", "'", " ", "\n", "\t"]:
		if url.contains(ch):
			return false
	return true


## Text without markup of its own: escaped, with bare links made clickable.
static func _plain(text: String) -> String:
	if text.is_empty():
		return ""
	var out := ""
	var cursor := 0
	for hit in TextLinks.find(text):
		out += escape(text.substr(cursor, hit[0] - cursor))
		var link: String = hit[2]
		if _is_safe_url(link):
			out += "[url=%s]%s[/url]" % [link, escape(text.substr(hit[0], hit[1] - hit[0]))]
		else:
			out += escape(text.substr(hit[0], hit[1] - hit[0]))
		cursor = hit[1]
	return out + escape(text.substr(cursor))
