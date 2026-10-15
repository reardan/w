// Native contract tests run by tools/mac/build_accessibility.sh.
#import "accessibility.m"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 100)];
        view.accessibilityChildren = @[];
        void *handle = w_access_open((__bridge void *)view, 32);
        assert(handle);
        w_access_begin(handle);
        assert(w_access_add(handle, 1, 0, 1, 0, 0));
        assert(w_access_add(handle, 2, 1, 6, 64, 1 | 2));
        assert(w_access_text(handle, 2, 1, "Open", 4));
        w_access_bounds(handle, 2, 8, 8, 80, 32);
        assert(w_access_add(handle, 3, 1, 8, 64, 2 | 4));
        assert(w_access_text(handle, 3, 2, "a\0b", 3));
        assert(w_access_commit(handle, 2));
        WAccessNode *root = view.accessibilityChildren[0];
        WAccessNode *button = root.accessibilityChildren[0];
        WAccessNode *editor = root.accessibilityChildren[1];
        assert([button.accessibilityLabel isEqualToString:@"Open"]);
        assert([button.accessibilityRole isEqualToString:NSAccessibilityButtonRole]);
        assert(button.isAccessibilityFocused);
        assert([editor.accessibilityValue length] == 3);
        assert([button accessibilityPerformPress]);
        intptr_t metadata[3];
        char bytes[32];
        assert(w_access_next(handle, metadata, bytes, 32) == 1);
        assert(metadata[0] == 2 && metadata[1] == 1 && metadata[2] == 0);
        [editor setAccessibilityValue:@"東京"];
        assert(w_access_next(handle, metadata, bytes, 1) == -1);
        assert(w_access_next(handle, metadata, bytes, 32) == 1);
        assert(metadata[0] == 3 && metadata[1] == 4 && metadata[2] == 6);
        assert(memcmp(bytes, "東京", 6) == 0);
        [button setAccessibilityFocused:YES];
        assert(w_access_next(handle, metadata, bytes, 32) == 1 && metadata[1] == 2);
        // Invalid UTF-16 must fail without constructing a dictionary with nil.
        unichar surrogate = 0xd800;
        NSString *invalid = [NSString stringWithCharacters:&surrogate length:1];
        [editor setAccessibilityValue:invalid];
        assert(w_access_next(handle, metadata, bytes, 32) == 0);
        // Readonly value, disabled ancestry, bounded queue, and stale clients.
        editor.states |= 16;
        [editor setAccessibilityValue:@"rejected"];
        assert(w_access_next(handle, metadata, bytes, 32) == 0);
        for (int i = 0; i < 64; ++i) assert([button accessibilityPerformPress]);
        assert(![button accessibilityPerformPress]);
        w_access_begin(handle);
        assert(w_access_add(handle, 1, 0, 1, 1, 0));
        assert(w_access_add(handle, 2, 1, 6, 64, 1));
        assert(w_access_commit(handle, 0));
        assert(![button accessibilityPerformPress]);
        assert(w_access_next(handle, metadata, bytes, 32) == 0);
        WAccessNode *disabled = [view.accessibilityChildren[0] accessibilityChildren][0];
        assert(!disabled.isAccessibilityEnabled);
        assert(![disabled accessibilityPerformPress]);
        // A malformed staging tree leaves the currently published tree intact.
        w_access_begin(handle);
        assert(!w_access_add(handle, 4, 999, 6, 0, 1));
        assert(!w_access_commit(handle, 0));
        assert([view.accessibilityChildren[0] accessibilityChildren][0] == disabled);
        w_access_close(handle);
        assert(view.accessibilityChildren.count == 0);
        assert(!disabled.isAccessibilityEnabled);
        assert(![disabled accessibilityPerformPress]);
        puts("native accessibility OK");
    }
    return 0;
}
