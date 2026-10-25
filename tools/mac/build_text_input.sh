#!/bin/sh
# Native companion for graphics.ime_cocoa; output goes beside the executable
# because W records @executable_path/libwtextinput.dylib.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p bin
xcrun clang -fobjc-arc -Wall -Wextra -Werror -dynamiclib \
  -framework AppKit -install_name @executable_path/libwtextinput.dylib \
  graphics/ui/native/text_input.m -o bin/libwtextinput.dylib
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework AppKit \
  graphics/ui/native/text_input_test.m -o bin/text_input_native_test
bin/text_input_native_test
