#!/usr/bin/env python3
"""Builds the hand-made TZif fixtures under tests/data/tz/Test/.

The other files in tests/data/tz/ are verbatim copies of the system's
/usr/share/zoneinfo (tzdata 2026c). Run from the repo root:
    python3 tests/data/tz/make_fixtures.py
"""
import struct

OUT = "tests/data/tz/Test/"


def header(version, isut, isstd, leap, timecnt, typecnt, charcnt):
    return b"TZif" + version + b"\0" * 15 + struct.pack(">6l", isut, isstd, leap, timecnt, typecnt, charcnt)


def block(times, idxs, types, chars, fmt):
    out = b"".join(struct.pack(fmt, t) for t in times)
    out += bytes(idxs)
    for utoff, isdst, abbrind in types:
        out += struct.pack(">lbB", utoff, isdst, abbrind)
    return out + chars


def footer_only(name, version, utoff, isdst, abbr, footer):
    chars = abbr.encode() + b"\0"
    types = [(utoff, isdst, 0)]
    v1 = header(version, 0, 0, 0, 0, 1, len(chars)) + block([], [], types, chars, ">l")
    v2 = header(version, 0, 0, 0, 0, 1, len(chars)) + block([], [], types, chars, ">q")
    with open(OUT + name, "wb") as f:
        f.write(v1 + v2 + b"\n" + footer.encode() + b"\n")


def v1_only(name, source):
    data = open(source, "rb").read()
    isut, isstd, leap, timecnt, typecnt, charcnt = struct.unpack(">6l", data[20:44])
    size = 44 + timecnt * 5 + typecnt * 6 + charcnt + leap * 8 + isstd + isut
    with open(OUT + name, "wb") as f:
        f.write(data[:4] + b"\0" + data[5:size])


v1_only("NewYorkV1", "tests/data/tz/America/New_York")
footer_only("Julian", b"2", -10800, 0, "AAA", "AAA3BBB,J60/0,300/1:30")
footer_only("NegativeDST", b"2", 3600, 0, "IST", "IST-1GMT0,M10.5.0,M3.5.0/1")
footer_only("AllYearDST", b"3", -14400, 1, "EDT", "EST5EDT,0/0,J365/25")
