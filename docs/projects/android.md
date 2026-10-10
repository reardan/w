# Experimental Android support

`arm64_android` targets 64-bit Android using the existing AArch64 emitter,
Android-specific runtime modules, and ELF output with 16 KB LOAD/RELRO
alignment. Plain programs are static PIE executables; programs importing
`c_lib` libraries use `/system/bin/linker64`. Use Android library names such
as `libc.so`, not glibc's `libc.so.6`. `--shared` emits an Android shared
library with AAPCS64 adapters for `export` functions. No NDK is needed to
compile ordinary W programs or the compiler itself.

Android defaults to `--pac=off` for the ARMv8.0 baseline. Explicit
`--pac=ret`/`--pac=full` require a device supporting pointer authentication;
they are not suitable for every Android CPU or emulator.

```sh
./wbuild build
bin/wv2 arm64_android --strict hello.w -o bin/hello_android
bin/wv2 arm64_android --shared graphics/android/demo.w -o bin/libwapp.so
```

The target works with `check`, `deps`, `symbols`, and `defhash`. Architecture
imports resolve through `__arch__/arm64_android`. The Android OS identifier
is 4; ISA and word size remain ARM64 and 8 bytes. Android uses raw kernel
syscalls for the W runtime. Its wrappers avoid `statx` and `close_range`,
which are not available under every Android app seccomp policy. Page-size
discovery uses the initial auxiliary vector or `/proc/self/auxv`, with an
allocation-free mapping probe fallback. Guard allocation and stack probing
use that runtime size. Android guard pages remain reserved with `PROT_NONE`
so another mapping cannot reuse the guard hole. Shell lookup respects PATH and falls back to
`/system/bin/sh`.

## Building on an ARM64 Android device

The initial supported command-line environment is Termux in its private
home directory. Shared storage such as `/sdcard` is unsuitable for build
executables. Install Git, a shell, and the usual core utilities in Termux.
An ARM64 Android seed is not yet published or pinned in `SEEDS`; a desktop
checkout supplies the initial local seed:

```sh
# On an existing supported build host:
./wbuild android_seed
# Transfer bin/w_android into the Android checkout as ./w_android.
```

Then, inside the Android checkout:

```sh
chmod +x w_android
sh ./wbuild build
sh ./wbuild verify
sh ./wbuild tests
```

`wbuild` detects Android and bootstraps `bin/wv2_android` and
`bin/wexec_android`. Native host planning maps `build`, `verify`, and `tests`
to the Android targets while retaining explicit cross-compilation selectors.
`verify_android` checks a compiler self-host fixpoint. `tests_android` is an
explicit, smaller device suite; it does not claim the complete desktop Linux
suite works on Android. `update_android` promotes a verified compiler to the
local seed only. A future published seed must follow the single-release-tag
rules in [release.md](../release.md), including real hashes for every pin.

## Native Android app

`graphics/android/ui.w` provides a small native-controls bridge: labels,
buttons, and single-line text fields. W owns application state; Android owns
rendering, keyboard/IME, scrolling, insets, and standard accessibility.
The existing OpenGL widget renderer has not been ported to native Android.
The browser/Wasm route remains available separately.

Requires an installed Android SDK platform 35 or newer, Build Tools 35 or
newer, an NDK (r28 or newer recommended), a JDK, and Python 3.9 or newer. The build
script runs on Linux or macOS and uses these installed tools directly; it does not download packages
or require Gradle. Set `ANDROID_HOME`/`ANDROID_SDK_ROOT`, or use `--sdk`.
`--ndk` and `--compiler` override automatic NDK selection and `bin/wv2`.

```sh
python3 tools/android/build.py
adb devices
python3 tools/android/smoke.py --serial DEVICE_SERIAL
```

Output: `bin/android/app/WApp.apk` and `preview.png`. The APK is a debuggable
development build signed with a generated local key under `bin/android/`.
It targets API 35, requires API 28, and packages only `arm64-v8a`. Custom
sources can replace the demo argument to `build.py`; they must implement:

```text
export void wandroid_setup()
export void wandroid_event(int handle, int kind, char* value)
export void wandroid_lifecycle(int phase)
```

All callbacks execute on the Activity UI thread. Handles are one-based and
reset when Android recreates the Activity; initialize W state in setup.
Event kinds are 1 for button clicks and 2 for edited text. The UTF-8 value is
borrowed for the callback duration; copy it before retaining. Phase 1 means
active and 2 background. The JNI bridge uses byte arrays for text so Unicode
outside the BMP survives round trips. Persisting state across process death
is the application's responsibility.

ARM64 export adapters preserve native callee-saved registers and reserve a
256 KiB W evaluation stack below the native frame. Keep callbacks within
that stack capacity. Exported library functions are regular C ABI functions;
ordinary W function pointers are not interchangeable with C callbacks.
Android native linking supports function imports and exports; external data,
thread-local storage, and W static-library output remain unsupported.

## Validation

The ordinary host suite includes Android ELF structure, host planning,
bootstrap selection, runtime layout, strict build-tool cross compilation,
and demo shared-library checks. These need neither an SDK nor a device:

```sh
./wbuild android_elf_test android_bootstrap_test android_build_tools_compile_test android_app_test
```

The optional device probes test exported integer/float arguments, stack
spills, relocated data, and a W compiler running inside Android's app sandbox:

```sh
python3 tools/android/build.py --probes
python3 tools/android/smoke.py --serial DEVICE_SERIAL --probes
```

The probe APK packages `compiler/cli.w` as a shared library and the runtime
sources as assets. It calls `compiler_main` once to compile a W fixture on
the device, loads that generated library, and checks containers, allocation,
page-size discovery, and guard allocation. It also exercises native controls,
W state changes, Unicode input, and the active lifecycle callback. This
embedded-compiler test does not replace the Termux compiler fixpoint test.

The APK probes have passed on Android 16 emulator images with 4 KB and
16 KB pages, running ARM64 libraries through `libndk_translation` on an
x86-64 host. The native controls, integer/float ABI, embedded compiler,
generated shared library, containers, and page-aware guard allocator were
exercised on both images. The screenshot produced by the 4 KB run was
visually inspected. These runs validate Android loader and sandbox behavior
but do not substitute for execution on physical ARM64 hardware.

Command-line self-hosting and executor termination can be reproduced over adb:

```sh
python3 tools/android/selfhost.py --serial DEVICE_SERIAL
ANDROID_SERIAL=DEVICE_SERIAL ./wbuild android_executor_signal_device_test
```

The self-host script builds a Bionic-linked ARM64 seed, stages its exact
source dependency closure under `/data/local/tmp/w-android-selfhost`,
checks `wv3 == wv4 == wv5`, and runs the runtime smoke. Both 4 KB and 16 KB
emulator runs passed, producing byte-identical compilers across page sizes.
The executor test also passed on both: SIGTERM exits 143, kills the child,
and releases its build lock. These commands require native ARM64 execution
or configured ARM64 binfmt translation. The dynamic dependency is necessary
for the emulator's program runner, which rejects static executables; these
adb-shell checks do not qualify the static-seed Termux bootstrap.

Physical ARM64 devices, Termux self-hosting, native debugging, and release
distribution require separate qualification. Android's app sandbox and
execution policies still apply; the presence of a desktop API in an import
closure does not make it usable inside an ordinary Android app.

References: [Termux execution environment](https://github.com/termux/termux-packages/wiki/Termux-execution-environment),
[Android page sizes](https://developer.android.com/guide/practices/page-sizes),
[Bionic linker requirements](https://android.googlesource.com/platform/bionic/+/master/android-changes-for-ndk-developers.md),
[Android app sandbox](https://source.android.com/docs/security/app-sandbox).
