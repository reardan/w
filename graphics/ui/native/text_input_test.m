// Native contract tests run by tools/mac/build_text_input.sh: drive the
// NSTextInputClient methods directly, as the input system would.
#import "text_input.m"
#include <assert.h>

static intptr_t next(void *handle, intptr_t *code) { return w_textin_next(handle, code); }

int main(void) {
    @autoreleasepool {
        NSView *parent = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        void *handle = w_textin_open((__bridge void *)parent);
        assert(handle);
        WTextInputView *view = (__bridge WTextInputView *)handle;
        intptr_t code = 0;
        // No focused field: keys are not routed.
        assert(w_textin_key(handle, NULL) == 0);
        w_textin_focus(handle, 7, 10, 20, 80, 16);
        assert(view.caret.origin.y == 64);
        // A dead key: marked accent, then the composed commit.
        [view setMarkedText:@"´" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(view.hasMarkedText);
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_BEGIN && code == 1);
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_TEXT && code == 0xb4);
        assert(next(handle, &code) == 0);
        [view insertText:@"é" replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(!view.hasMarkedText);
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_END);
        assert(next(handle, &code) == W_TEXTIN_COMMIT && code == 0xe9);
        // Selection offsets count scalars, not UTF-16 units.
        [view setMarkedText:@"😀中" selectedRange:NSMakeRange(2, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_BEGIN && code == 1);
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_TEXT && code == 0x1f600);
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_TEXT && code == 0x4e2d);
        NSRange actual;
        assert([[[view attributedSubstringForProposedRange:NSMakeRange(2, 5) actualRange:&actual] string] isEqualToString:@"中"]);
        assert(actual.location == 2 && actual.length == 1);
        // unmarkText commits the marked text as typed.
        [view unmarkText];
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_END);
        assert(next(handle, &code) == W_TEXTIN_COMMIT && code == 0x1f600);
        assert(next(handle, &code) == W_TEXTIN_COMMIT && code == 0x4e2d);
        // An empty marked string ends the composition without a commit.
        [view setMarkedText:[[NSAttributedString alloc] initWithString:@"k"] selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_BEGIN);
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_TEXT && code == 'k');
        [view setMarkedText:@"" selectedRange:NSMakeRange(0, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
        assert(next(handle, &code) == W_TEXTIN_PREEDIT_END);
        assert(next(handle, &code) == 0);
        // A focus change drops the composition and never commits it.
        [view setMarkedText:@"x" selectedRange:NSMakeRange(1, 0) replacementRange:NSMakeRange(NSNotFound, 0)];
        while (next(handle, &code) != 0) {}
        w_textin_focus(handle, 8, 0, 0, 10, 10);
        assert(!view.hasMarkedText);
        assert(next(handle, &code) == 0);
        assert([view markedRange].location == NSNotFound);
        assert([view hitTest:NSMakePoint(5, 5)] == nil);
        w_textin_close(handle);
        assert(parent.subviews.count == 0);
    }
    puts("text input native OK");
    return 0;
}
