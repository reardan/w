# Native iOS bootstrap

W can emit native Apple Silicon iPhone/iPad and iOS Simulator executables:

```sh
bin/wv2 arm64_ios graphics/ios/demo.w -o bin/ios_device
bin/wv2 arm64_ios_sim graphics/ios/demo.w -o bin/ios_simulator
```

These targets use the ARM64 emitter and Darwin ABI, with distinct Mach-O
`LC_BUILD_VERSION` platforms: iOS = 2, Simulator = 7. The deployment baseline
is iOS 17. `arm64_darwin` remains macOS (platform 1, minimum macOS 12).
The platform selectors work with `check`, `deps`, `symbols`, and `defhash`.
`__arch__` resolves to separate `arm64_ios`/`arm64_ios_sim` directories;
the Darwin runtime modules are shared through `lib/darwin/`.

This first native path uses `graphics/ios/ui.w`, a small UIKit controls API.
The demo creates labels, a text field and a button from W. W owns the counter
and event handlers; UIKit owns rendering, safe-area layout, scrolling,
software keyboard/IME, Dynamic Type, and native accessibility semantics.
The existing OpenGL `graphics/ui/widgets.w` renderer is **not yet ported to
iOS**. Importing its window backend on iOS fails rather than linking AppKit.
Mobile web uses the separate wasm browser backend.

## Build and run on a Mac

Requires Apple Silicon, Xcode with iOS SDKs, and an installed iOS Simulator
runtime. The W compiler itself can cross-compile the executable from Linux;
packaging the UIKit framework requires Apple's SDK and clang.

```sh
./wbuild build_darwin
# Build an ad-hoc-signed simulator .app:
tools/ios/build.sh simulator
# Build, boot an available iPhone simulator, install, exercise the callback,
# launch interactively, and save bin/ios/simulator/preview.png:
tools/ios/smoke.sh
# Or select a simulator explicitly:
xcrun simctl list devices available
tools/ios/smoke.sh SIMULATOR_UDID
```

`W_COMPILER=/path/to/compiler` selects a different executable compiler.
`tools/ios/build.sh simulator path/to/app.w` packages another W program using
this bridge. The output is `bin/ios/simulator/WApp.app`. The bundle identifier
defaults to `org.wlang.native-demo`; override with `W_IOS_BUNDLE_ID`.

## Device build and signing

```sh
tools/ios/build.sh device
```

This writes `bin/ios/device/WApp.app` with a device-platform executable and
UIKit framework. An unprovisioned build is **not installable on an iPhone**.
To sign for your own device, provide an installed signing identity and the
matching provisioning profile and entitlements:

```sh
W_IOS_BUNDLE_ID=com.example.myapp \
W_IOS_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)' \
W_IOS_PROFILE=/absolute/path/MyApp.mobileprovision \
W_IOS_ENTITLEMENTS=/absolute/path/MyApp.entitlements \
  tools/ios/build.sh device
```

The profile must include your device and bundle ID. Entitlements must match
that profile, including `application-identifier` and
`com.apple.developer.team-identifier`. The script signs the embedded framework
before the app and copies the profile into the bundle. Installation can then
use Xcode's Devices and Simulators window or `xcrun devicectl device install
app --device DEVICE_ID bin/ios/device/WApp.app`.

No physical device or distribution signing has been qualified yet. This is an
experimental development bootstrap, not an App Store release pipeline.

## Host and callback contract

The W executable is the app's main Mach-O; its only custom dynamic dependency
is `@executable_path/Frameworks/WIOS.framework/WIOS`. `tools/ios/host.m` starts
`UIApplicationMain` on the main thread, retains native controls and callback
objects, and exposes a minimal C ABI imported by W. There is no web view or JIT.

W ARM64 function pointers are **not C function pointers**. UIKit callbacks enter
`tools/ios/callback.S`, which preserves the AAPCS64 callee-saved integer and FP
registers and provides a 256 KiB W evaluation stack. Callbacks take no arguments;
state lives in W globals and control values are read using handles. Keep these
callbacks shallow; the bridge does not offer an unbounded coroutine stack.
Use the default PAC mode (`ret`) or `off`; the bridge does not authenticate
`--pac=full` signed callback pointers.

All bridge calls and callbacks run on UIKit's main thread. Handles are stable,
1-based integers for the lifetime of the app. `wios_text_value` returns a
borrowed UTF-8 pointer; copy it if retaining it past a text change.
`wios_run(argc, argv, title, setup, lifecycle)` invokes `setup` after installing
the view. The optional lifecycle callback reads `wios_phase()` (1 active,
2 background). Native controls supply VoiceOver roles and text; the W API is
intentionally small and does not yet expose custom accessibility actions.

## Verification and remaining work

`./wbuild ios_target_test` is a cross-host gate in `tests`. It compiles the W
demo for both platforms, checks diagnostics/dependency resolution/symbol arch
identity, and parses the emitted Mach-O files (including a macOS compatibility case)
to assert platform/deployment,
ARM64, PIE, W^X, entry point, bridge load command, and embedded signature.
It needs neither Xcode nor a simulator. The new platforms currently use
explicit source-owned `# wbuild: step=` directives; generic `arch=` test twins
have not been added to the manifest generator.

`tools/ios/smoke.sh` adds the Apple SDK/framework build, simulator installation,
and a real UIKit -> W -> UIKit button callback. This was run successfully on
an iPhone 17 Pro simulator with iOS 26.3; both device and simulator SDK builds
were validated with Xcode's 26.2 SDKs. A normal-launch screenshot was inspected.
The simulator smoke does not replace manual device checks for keyboard/IME,
VoiceOver, suspension, rotation, or memory pressure.

Next native milestones are a shared `graphics/ui` renderer (Metal or another
supported rendering layer), richer controls and event/value APIs, scene-based
multiwindow lifecycle, device qualification, and a release/signing workflow.
The inherited low-level Darwin runtime contains APIs that iOS sandboxing will
reject; their presence is not a claim that every desktop library is supported.
