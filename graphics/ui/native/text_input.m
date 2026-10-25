// NSTextInputClient companion for graphics.window_cocoa (graphics.ime_cocoa).
// Build with ARC: tools/mac/build_text_input.sh. A transparent first-responder
// view routes W's key-downs through interpretKeyEvents:, so dead keys, the
// Character Viewer and IMEs compose; it queues committed text and marked-text
// snapshots as scalar events that W drains into its input queue.
#import <AppKit/AppKit.h>
#include <stdint.h>

// Queue entry kinds; graphics/ime_cocoa.w maps them to GFX_EVENT_*.
enum { W_TEXTIN_COMMIT = 1, W_TEXTIN_PREEDIT_BEGIN = 2, W_TEXTIN_PREEDIT_TEXT = 3, W_TEXTIN_PREEDIT_END = 4 };
enum { W_TEXTIN_QUEUE_LIMIT = 8192 };

@interface WTextInputView : NSView <NSTextInputClient>
@property(nonatomic, strong) NSMutableArray<NSNumber *> *queue;
@property(nonatomic, copy) NSString *marked;
@property(nonatomic) NSRange markedSelection;
@property(nonatomic) NSRect caret;
@property(nonatomic) intptr_t focus;
@property(nonatomic) BOOL textChanged;
@property(nonatomic) BOOL command;
@property(nonatomic) BOOL discarding;
@end

static NSString *plainString(id string) {
    if ([string isKindOfClass:[NSAttributedString class]]) return [string string];
    if ([string isKindOfClass:[NSString class]]) return string;
    return @"";
}

@implementation WTextInputView

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return NO; }
// Clicks fall through to the GL view; W reads mouse events before sendEvent:.
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
// Command chords reach the first responder through sendEvent:; W already
// queued them, so do not beep.
- (void)keyDown:(NSEvent *)event { (void)event; }

- (void)push:(intptr_t)kind code:(intptr_t)code {
    if (self.queue.count + 2 > W_TEXTIN_QUEUE_LIMIT) return;
    [self.queue addObject:@(kind)];
    [self.queue addObject:@(code)];
}

// Queue each Unicode scalar of text; unpaired surrogates are skipped.
- (void)pushScalars:(NSString *)text kind:(intptr_t)kind {
    NSUInteger n = text.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        uint32_t cp = c;
        if (c >= 0xd800 && c <= 0xdbff && i + 1 < n) {
            unichar d = [text characterAtIndex:i + 1];
            if (d >= 0xdc00 && d <= 0xdfff) {
                cp = 0x10000 + ((uint32_t)(c - 0xd800) << 10) + (d - 0xdc00);
                i++;
            }
        }
        if (cp >= 0xd800 && cp <= 0xdfff) continue;
        [self push:kind code:cp];
    }
}

// Scalars in the first utf16 units of text.
static intptr_t scalarOffset(NSString *text, NSUInteger utf16) {
    intptr_t n = 0;
    NSUInteger limit = MIN(utf16, text.length);
    for (NSUInteger i = 0; i < limit; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= 0xdc00 && c <= 0xdfff && i > 0) {
            unichar p = [text characterAtIndex:i - 1];
            if (p >= 0xd800 && p <= 0xdbff) continue;
        }
        n++;
    }
    return n;
}

- (void)endMarked {
    if (self.marked.length == 0) return;
    self.marked = @"";
    self.markedSelection = NSMakeRange(0, 0);
    [self push:W_TEXTIN_PREEDIT_END code:0];
}

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    if (self.discarding) return;
    [self endMarked];
    [self pushScalars:plainString(string) kind:W_TEXTIN_COMMIT];
    self.textChanged = YES;
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    if (self.discarding) return;
    NSString *text = plainString(string);
    self.textChanged = YES;
    if (text.length == 0) {
        [self endMarked];
        return;
    }
    self.marked = text;
    self.markedSelection = selectedRange;
    [self push:W_TEXTIN_PREEDIT_BEGIN code:scalarOffset(text, selectedRange.location)];
    [self pushScalars:text kind:W_TEXTIN_PREEDIT_TEXT];
}

// The input system fixes the marked text as typed: commit it.
- (void)unmarkText {
    NSString *text = self.marked;
    if (text.length == 0) return;
    [self endMarked];
    if (!self.discarding) [self pushScalars:text kind:W_TEXTIN_COMMIT];
    self.textChanged = YES;
}

- (BOOL)hasMarkedText { return self.marked.length > 0; }

- (NSRange)markedRange {
    if (self.marked.length == 0) return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(0, self.marked.length);
}

// W owns the field's text, so only the marked text has a known range.
- (NSRange)selectedRange {
    if (self.marked.length == 0) return NSMakeRange(0, 0);
    return self.markedSelection;
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[]; }

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (self.marked.length == 0 || range.location >= self.marked.length) return nil;
    NSRange clipped = NSIntersectionRange(range, NSMakeRange(0, self.marked.length));
    if (actualRange) *actualRange = clipped;
    return [[NSAttributedString alloc] initWithString:[self.marked substringWithRange:clipped]];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point;
    return NSNotFound;
}

// The candidate window sits under the focused field's rectangle.
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    if (actualRange) *actualRange = range;
    NSRect inWindow = [self convertRect:self.caret toView:nil];
    if (!self.window) return inWindow;
    return [self.window convertRectToScreen:inWindow];
}

// A key the input system did not turn into text: W translates it itself.
- (void)doCommandBySelector:(SEL)selector {
    (void)selector;
    self.command = YES;
}

@end

void *w_textin_open(void *viewPointer) {
    NSView *parent = (__bridge NSView *)viewPointer;
    if (!parent) return NULL;
    WTextInputView *view = [[WTextInputView alloc] initWithFrame:parent.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.queue = [NSMutableArray array];
    view.marked = @"";
    [parent addSubview:view];
    if (parent.window) [parent.window makeFirstResponder:view];
    return (__bridge_retained void *)view;
}

// Route one key-down through the input system. Returns 1 when it composed
// or committed text (or swallowed the key while composing), 0 when the key
// came back as a command or no text field is focused.
intptr_t w_textin_key(void *handle, void *eventPointer) {
    WTextInputView *view = (__bridge WTextInputView *)handle;
    NSEvent *event = (__bridge NSEvent *)eventPointer;
    if (!view || !event || view.focus == 0) return 0;
    BOOL wasMarked = view.hasMarkedText;
    view.textChanged = NO;
    view.command = NO;
    [view interpretKeyEvents:@[event]];
    if (view.textChanged) return 1;
    return (wasMarked && !view.command) ? 1 : 0;
}

// Pop one queued entry: returns its kind with *code set, or 0 when empty.
intptr_t w_textin_next(void *handle, intptr_t *code) {
    WTextInputView *view = (__bridge WTextInputView *)handle;
    if (!view || view.queue.count < 2) return 0;
    intptr_t kind = view.queue[0].integerValue;
    *code = view.queue[1].integerValue;
    [view.queue removeObjectsInRange:NSMakeRange(0, 2)];
    return kind;
}

// The focused field (0 = none) and its rectangle in top-left window
// coordinates. A focus change discards any composition in progress.
void w_textin_focus(void *handle, intptr_t focus, double x, double y, double width, double height) {
    WTextInputView *view = (__bridge WTextInputView *)handle;
    if (!view) return;
    if (focus != view.focus) {
        if (view.hasMarkedText) {
            view.discarding = YES;
            [view.inputContext discardMarkedText];
            view.discarding = NO;
            view.marked = @"";
            view.markedSelection = NSMakeRange(0, 0);
        }
        view.focus = focus;
    }
    double top = view.bounds.size.height - y - height;
    view.caret = NSMakeRect(x, top, width, height);
    if (focus != 0 && view.window && view.window.firstResponder != view) [view.window makeFirstResponder:view];
}

void w_textin_close(void *handle) {
    WTextInputView *view = (__bridge_transfer WTextInputView *)handle;
    [view removeFromSuperview];
}
