#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path


IDENT = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"


def previous_identifier(text, quote_index):
	i = quote_index - 1
	while i >= 0 and text[i] in " \t\r\n":
		i -= 1
	end = i + 1
	while i >= 0 and text[i] in IDENT:
		i -= 1
	return text[i + 1:end]


def rewrite(text):
	out = []
	i = 0
	state = "code"
	while i < len(text):
		c = text[i]
		n = text[i + 1] if i + 1 < len(text) else ""
		if state == "line_comment":
			out.append(c)
			if c == "\n":
				state = "code"
			i += 1
		elif state == "block_comment":
			out.append(c)
			if c == "*" and n == "/":
				out.append(n)
				i += 2
				state = "code"
			else:
				i += 1
		elif state == "char":
			out.append(c)
			if c == "\\" and n:
				out.append(n)
				i += 2
			else:
				if c == "'":
					state = "code"
				i += 1
		else:
			if c == "#":
				out.append(c)
				state = "line_comment"
				i += 1
			elif c == "/" and n == "*":
				out.append(c)
				out.append(n)
				state = "block_comment"
				i += 2
			elif c == "'":
				out.append(c)
				state = "char"
				i += 1
			elif c == '"':
				prev = text[i - 1] if i > 0 else ""
				keyword = previous_identifier(text, i)
				if prev not in "cs" and keyword not in ("c_lib", "c_import"):
					out.append("c")
				out.append(c)
				i += 1
				while i < len(text):
					out.append(text[i])
					if text[i] == "\\" and i + 1 < len(text):
						i += 1
						out.append(text[i])
					elif text[i] == '"':
						i += 1
						break
					i += 1
			else:
				out.append(c)
				i += 1
	return "".join(out)


def tracked_w_files():
	result = subprocess.run(
		["git", "ls-files", "*.w"],
		check=True,
		stdout=subprocess.PIPE,
		text=True,
	)
	return [Path(line) for line in result.stdout.splitlines() if line]


def main():
	check = "--check" in sys.argv
	changed = []
	for path in tracked_w_files():
		original = path.read_text()
		updated = rewrite(original)
		if updated != original:
			changed.append(str(path))
			if not check:
				path.write_text(updated)
	if check and changed:
		for path in changed:
			print(path)
		return 1
	for path in changed:
		print(path)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
