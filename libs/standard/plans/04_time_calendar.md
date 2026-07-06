# Plan: time, datetime, calendar, and zones

## Target area

Base code directory: `libs/standard/time/`

Suggested modules:

- `libs.standard.time.datetime`
- `libs.standard.time.calendar`
- `libs.standard.time.zoneinfo`
- `libs.standard.time.clock`
- `libs.standard.time.format`

## Python 3.14 reference implementations

Consult these CPython sources first:

- `Lib/datetime.py` and `Modules/_datetimemodule.c` - date/time/datetime/timedelta.
- `Lib/calendar.py` - month/day calculations and text calendars.
- `Lib/zoneinfo/` - IANA zone loading and fold behavior.
- `Modules/timemodule.c` - clocks, sleep, and platform time wrappers.
- `Lib/_strptime.py` - parsing formatted date/time strings.

## Current W starting point

- `lib/time.w` supports Unix seconds, monotonic milliseconds, sleep, UTC
  timestamp decomposition, and `"YYYY-MM-DD HH:MM:SS"` formatting.
- x86 `time_now()` has a documented 2038 limitation.
- No local time, time zones, calendar formatting, parsing, or duration type.

## Goals

1. Introduce value types for date, time of day, datetime, and duration.
2. Provide calendar arithmetic independent of system local time.
3. Provide robust formatting/parsing for ISO-like formats.
4. Add zoneinfo later with explicit IANA data loading.
5. Preserve existing `lib.time` as the low-level clock layer.

## Non-goals for MVP

- No system locale names for days/months.
- No leap-second modeling.
- No full `strftime`/`strptime` directive matrix initially.
- No automatic use of host `/usr/share/zoneinfo` until file APIs are ready.

## API sketch

`datetime.w`

- `struct date { int year; int month; int day }`
- `struct time_of_day { int hour; int minute; int second; int microsecond }`
- `struct datetime { date d; time_of_day t; int tz_offset_seconds; int has_tz }`
- `struct timedelta { int days; int seconds; int microseconds }`
- `int date_valid(int year, int month, int day)`
- `date date_from_ordinal(int ordinal)`
- `int date_to_ordinal(date d)`
- `datetime datetime_from_unix_utc(int timestamp)`
- `int datetime_to_unix_utc(datetime dt, int* out_timestamp)`
- `datetime datetime_add(datetime dt, timedelta delta)`
- `int datetime_compare(datetime a, datetime b)`

`calendar.w`

- `int calendar_isleap(int year)`
- `int calendar_weekday(int year, int month, int day)`
- `int calendar_monthrange(int year, int month, int* weekday, int* days)`
- `list[list[int]] calendar_monthcalendar(int year, int month)`

`clock.w`

- `int clock_time_seconds()`
- `int clock_monotonic_ms()`
- `int clock_perf_counter_us()` if supported.
- `void clock_sleep_ms(int ms)`

`format.w`

- `char* datetime_isoformat(datetime dt)`
- `int datetime_parse_iso(char* text, datetime* out)`
- `char* date_isoformat(date d)`
- `int date_parse_iso(char* text, date* out)`

`zoneinfo.w`

- `zoneinfo* zoneinfo_load(char* name)`
- `int zoneinfo_offset_at(zoneinfo* zone, int unix_timestamp)`
- `datetime datetime_from_unix_zone(int timestamp, zoneinfo* zone)`

## Implementation phases

### Phase 1: date and calendar arithmetic

- Port Python's proleptic Gregorian rules.
- Use ordinal-day algorithms for add/subtract/compare.
- Tests: leap years, invalid dates, month lengths, weekday known dates, Python
  examples from `datetime`/`calendar` docs.

### Phase 2: duration and UTC datetime

- Add `timedelta` normalization.
- Convert between Unix timestamps and UTC datetimes.
- Handle negative timestamps if W integer range allows; otherwise document.
- Tests: epoch, before epoch if supported, day rollover, microsecond carry.

### Phase 3: formatting/parsing

- Implement ISO date and datetime formatting.
- Parse strict forms first: `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SS`, optional `Z`,
  optional numeric offset.
- Tests: valid strings, invalid ranges, round trips.

### Phase 4: clock wrappers

- Wrap existing `lib.time` functions under the standard namespace.
- Add target-specific clock_gettime variants to fix x86 2038 where possible.
- Tests: monotonic clock does not go backwards in a short sample, sleep returns.

### Phase 5: zoneinfo

- Implement TZif parser for IANA files.
- Search paths: env override first, then `/usr/share/zoneinfo`.
- Start with fixed-offset and UTC before full DST transition lookup.
- Tests: UTC, fixed offsets, one real zone fixture committed under tests.

## Compatibility notes from Python

- Python `datetime` supports rich arithmetic, timezone objects, `fold`, and
  microsecond precision. W can represent the data but should postpone object
  polymorphism.
- Python uses arbitrary-size ints for ordinals/timestamps. W must document valid
  ranges per target.
- Python `zoneinfo` depends on IANA data outside the stdlib on some systems. W
  should allow explicit zone data paths to keep tests hermetic.

## Acceptance criteria

- Date/calendar functions match Python for a documented matrix of dates.
- UTC datetime round trips through Unix timestamp conversion.
- ISO parse/format round trips for supported forms.
- Zoneinfo MVP can load UTC/fixed offset and has a clear path to TZif support.
