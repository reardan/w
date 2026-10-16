#!/usr/bin/env python3
"""Prints the generated expectation block of libs/standard/time/zoneinfo_test.w.

Expected values come from Python's zoneinfo (ZoneInfo.from_file) on the
fixture files in this directory, so they never depend on the host's
/usr/share/zoneinfo. For the footers with Jn / n rule dates (Test/Julian,
Test/AllYearDST) Python 3.13 is off by one day, so those use the pure
Python implementation with POSIX day numbering patched in, cross-checked
against glibc's own TZ-string handling. Run from the repo root:
    python3 tests/data/tz/gen_cases.py > /tmp/cases.w
and paste the output between the GENERATED markers of the test.
"""
import calendar
import os
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from zoneinfo import _zoneinfo as pure

ROOT = "tests/data/tz/"
UTC = timezone.utc
INT32_MIN = -(2 ** 31)
INT32_MAX = 2 ** 31 - 1


def posix_year_to_epoch(self, year):
    days_before_year = pure._post_epoch_days_before_year(year)
    d = self.d
    if self.julian:
        if d >= 60 and calendar.isleap(year):
            d += 1
    else:
        d += 1
    epoch = (days_before_year + d) * 86400
    return epoch + self.hour * 3600 + self.minute * 60 + self.second


# (function suffix, key, years scanned, oracle, footer string for glibc)
ZONES = [
    ("new_york", "America/New_York", [1883, 1918, 1945, 1974, 2007, 2023, 2037, 2038, 2100, 2400], "c", None),
    ("london", "Europe/London", [1847, 1916, 1968, 1971, 2024, 2100], "c", None),
    ("dublin", "Europe/Dublin", [1916, 1971, 2024, 2060], "c", None),
    ("lord_howe", "Australia/Lord_Howe", [1981, 1985, 2024, 2090], "c", None),
    ("kolkata", "Asia/Kolkata", [1854, 1942, 1945, 2020, 2200], "c", None),
    ("utc", "UTC", [2000, 2100], "c", None),
    ("nuuk", "America/Nuuk", [1916, 1980, 2023, 2024, 2030], "c", None),
    ("new_york_v1", "Test/NewYorkV1", [1918, 2023, 2037, 2040], "c", None),
    ("negative_dst", "Test/NegativeDST", [2023, 2100], "c", "IST-1GMT0,M10.5.0,M3.5.0/1"),
    ("julian", "Test/Julian", [2023, 2024, 2100], "posix", "AAA3BBB,J60/0,300/1:30"),
    ("all_year_dst", "Test/AllYearDST", [2023, 2024], "posix", "EST5EDT,0/0,J365/25"),
]


def load(key, oracle):
    with open(ROOT + key, "rb") as f:
        if oracle == "c":
            return ZoneInfo.from_file(f, key=key)
        return pure.ZoneInfo.from_file(f, key=key)


def off(z, dt):
    return int(dt.replace(tzinfo=z).utcoffset().total_seconds())


def transitions(z, year):
    """UTC seconds at which the offset changes during year, with shifts."""
    out = []
    start = int(datetime(year, 1, 1, tzinfo=UTC).timestamp())
    end = int(datetime(year + 1, 1, 1, tzinfo=UTC).timestamp())
    def at(ts):
        return int(datetime.fromtimestamp(ts, z).utcoffset().total_seconds())
    prev = at(start)
    t = start
    while t < end:
        nxt = min(t + 3600, end)
        cur = at(nxt)
        if cur != prev:
            lo, hi = t, nxt
            while hi - lo > 1:
                mid = (lo + hi) // 2
                if at(mid) == prev:
                    lo = mid
                else:
                    hi = mid
            out.append((hi, prev, cur))
        prev = cur
        t = nxt
    return out


def fields(dt):
    return f"{dt.year}, {dt.month}, {dt.day}, {dt.hour}, {dt.minute}, {dt.second}"


def emit_zone(suffix, key, years, oracle, footer):
    z = load(key, oracle)
    has_table = not key.startswith("Test/") or key == "Test/NewYorkV1"
    lines = {False: [], True: []}
    seen = set()
    def x64_only(*dts):
        return has_table and any(d.year < 1902 for d in dts)
    def add_utc(ts):
        if ("u", ts) in seen:
            return
        seen.add(("u", ts))
        u = datetime(1970, 1, 1) + timedelta(seconds=ts)
        local = u.replace(tzinfo=UTC).astimezone(z)
        lines[x64_only(u, local)].append(
            f"\tzt_utc(z, {fields(u)}, {fields(local)}, {int(local.utcoffset().total_seconds())}, "
            f"{int(local.dst().total_seconds())}, c\"{local.tzname()}\", {local.fold})")
    def add_local(w):
        if ("l", w) in seen:
            return
        seen.add(("l", w))
        for fold in (0, 1):
            d = w.replace(tzinfo=z, fold=fold)
            lines[x64_only(w)].append(
                f"\tzt_local(z, {fields(w)}, {fold}, {int(d.utcoffset().total_seconds())}, "
                f"{int(d.dst().total_seconds())}, c\"{d.tzname()}\")")
    for year in years:
        trs = transitions(z, year)
        add_utc(int(datetime(year, 6, 15, 12, tzinfo=UTC).timestamp()))
        add_local(datetime(year, 1, 15, 12))
        for (s, before, after) in trs:
            shift = abs(before - after)
            for ts in (s - 1, s, s + shift - 1, s + shift):
                add_utc(ts)
            base = datetime(1970, 1, 1) + timedelta(seconds=s)
            lo, hi = sorted((before, after))
            for delta in (lo - 1, lo, (lo + hi) // 2, hi - 1, hi):
                add_local(base + timedelta(seconds=delta))
    if footer:
        os.environ["TZ"] = footer
        time.tzset()
        for year in years:
            # Python evaluates a footer one UTC year at a time, so a DST
            # period spanning New Year (all-year DST) differs from glibc
            # in the first hours of January; compare from Jan 3 on.
            for h in range(48, 363 * 24, 5):
                ts = int(datetime(year, 1, 1, tzinfo=UTC).timestamp()) + h * 3600 + 1234
                got = int(datetime.fromtimestamp(ts, z).utcoffset().total_seconds())
                assert got == time.localtime(ts).tm_gmtoff, (key, ts)
    print(f"void zcases_{suffix}(zoneinfo* z):")
    print("\n".join(lines[False]))
    print()
    print()
    if lines[True]:
        print(f"void zcases_{suffix}_64(zoneinfo* z):")
        print("\n".join(lines[True]))
        print()
        print()


pure._DayOffset.year_to_epoch = posix_year_to_epoch
for zone in ZONES:
    emit_zone(*zone)
