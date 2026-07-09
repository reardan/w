/*
graphics.cocoa: the Objective-C runtime surface the Cocoa window backend
is built on (arm64_darwin only).

Everything goes through objc_msgSend, bound once per call signature with
the extern-alias syntax: the AAPCS64 shim only needs the argument
classes, and objc_msgSend itself is signature-polymorphic. Receivers,
classes, selectors and objects all travel as word-sized W ints.

HARD RULE: never bind a struct-RETURNING selector (frame,
locationInWindow, contentRectForFrameRect:, ...). Those return through
x8/HFA conventions the shim does not model; this backend avoids every
such selector by design. Struct ARGUMENTS are fine when flattened:
an NSRect argument is an HFA of 4 doubles, which lands in v0-v3 exactly
like 4 scalar float64 parameters (objc_msg_rect3 below relies on this).
Narrow returns (BOOL, unsigned short) arrive with garbage in the high
bits — callers mask (& 0xff / & 0xffff).

AppKit is loaded purely so its classes exist for objc_getClass; no
AppKit symbol is bound directly (Foundation arrives via AppKit's own
dependencies).
*/
import lib.lib


c_lib "/usr/lib/libobjc.A.dylib"

extern int objc_getClass(char* name)
extern int sel_registerName(char* name)
extern int objc_autoreleasePoolPush()
extern void objc_autoreleasePoolPop(int pool)

# objc_msgSend, once per signature. Integer/pointer arguments only —
# except objc_msg_rect3, whose leading NSRect is flattened to 4 float64s.
extern int objc_msg0(int receiver, int selector) = "objc_msgSend"
extern int objc_msg1(int receiver, int selector, int a) = "objc_msgSend"
extern int objc_msg2(int receiver, int selector, int a, int b) = "objc_msgSend"
extern int objc_msg4(int receiver, int selector, int a, int b, int c, int d) = "objc_msgSend"
# initWithContentRect:styleMask:backing:defer: — NSRect in v0-v3, the
# three integer arguments after the receiver+selector in x2-x4.
extern int objc_msg_rect3(int receiver, int selector, float64 x, float64 y, float64 w, float64 h, int a, int b, int c) = "objc_msgSend"

c_lib "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
