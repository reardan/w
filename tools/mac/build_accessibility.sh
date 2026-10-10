#!/bin/sh
# Native companion for graphics.ui.accessibility_cocoa; output goes beside the
# executable because W records @executable_path/libwaccessibility.dylib.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p bin
xcrun clang -fobjc-arc -Wall -Wextra -Werror -dynamiclib \
  -framework AppKit -install_name @executable_path/libwaccessibility.dylib \
  graphics/ui/native/accessibility.m -o bin/libwaccessibility.dylib
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
  graphics/ui/native/accessibility_test.m -o bin/accessibility_native_test
bin/accessibility_native_test
