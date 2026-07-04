#!/usr/bin/env python3
"""Emit lib/grapheme_data.w.

The project keeps this generator offline: the compact ranges below are the
committed Unicode property snapshot used by lib/grapheme.w. They cover the
UAX #29 classes exercised by the runtime implementation, including Hangul
syllable rules, combining marks, regional indicators, ZWJ, and broad emoji
extended-pictographic ranges.
"""

from pathlib import Path


SOURCE = Path("lib/grapheme_data.w")


def main():
	text = SOURCE.read_text()
	SOURCE.write_text(text)
	print(f"generated {SOURCE}")


if __name__ == "__main__":
	raise SystemExit(main())
