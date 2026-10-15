// NSAccessibility adapter for custom-rendered W controls. Build with ARC.
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <string.h>

@class WAccessBridge;
@interface WAccessNode : NSAccessibilityElement
@property(nonatomic, weak) WAccessBridge *bridge;
@property(nonatomic) NSInteger nodeID;
@property(nonatomic) NSInteger states;
@property(nonatomic) NSInteger actions;
@property(nonatomic) NSInteger roleCode;
@property(nonatomic) NSInteger heading;
@property(nonatomic) NSRect logicalFrame;
@property(nonatomic, copy) NSString *nodeValue;
@property(nonatomic) BOOL focused;
@end

@interface WAccessBridge : NSObject
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) NSArray *savedChildren;
@property(nonatomic) BOOL savedElement;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, WAccessNode *> *nodes;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, WAccessNode *> *staging;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, strong) WAccessNode *root;
@property(nonatomic, strong) WAccessNode *stagingRoot;
@property(nonatomic) NSInteger maxBytes;
@property(nonatomic) NSInteger focusedID;
@property(nonatomic) BOOL building;
@property(nonatomic) BOOL failed;
@end
@implementation WAccessBridge
@end

static BOOL enqueue(WAccessNode *node, NSInteger action, NSString *value) {
    WAccessBridge *bridge = node.bridge;
    if (!bridge || (node.states & (1 | 32)) || !(node.actions & action)) return NO;
    if (action == 4 && (node.states & 16)) return NO;
    if (bridge.events.count >= 64) return NO;
    NSData *bytes = [(value ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (!bytes || bytes.length > (NSUInteger)bridge.maxBytes) return NO;
    [bridge.events addObject:@{@"id": @(node.nodeID), @"action": @(action), @"data": bytes}];
    return YES;
}

@implementation WAccessNode
- (BOOL)isAccessibilityElement { return self.bridge != nil && !(self.states & 32); }
- (BOOL)isAccessibilityEnabled { return self.bridge != nil && !(self.states & 1); }
- (BOOL)isAccessibilityFocused { return self.focused; }
- (void)setAccessibilityFocused:(BOOL)focused { if (focused) enqueue(self, 2, nil); }
- (BOOL)isAccessibilitySelected { return (self.states & 4) != 0; }
- (BOOL)isAccessibilityExpanded { return (self.states & 8) != 0; }
- (NSInteger)accessibilityHeadingLevel { return self.heading; }
- (id)accessibilityValue {
    if (self.roleCode == 7) return @((self.states & 2) != 0);
    return self.nodeValue ?: @"";
}
- (void)setAccessibilityValue:(id)value {
    if ([value isKindOfClass:[NSString class]]) enqueue(self, 4, value);
}
- (BOOL)accessibilityPerformPress {
    return enqueue(self, (self.actions & 8) ? 8 : 1, nil);
}
- (BOOL)isAccessibilitySelectorAllowed:(SEL)selector {
    if (selector == @selector(accessibilityPerformPress)) return (self.actions & (1 | 8)) && !(self.states & (1 | 32));
    if (selector == @selector(setAccessibilityValue:)) return (self.actions & 4) && !(self.states & (1 | 16 | 32));
    if (selector == @selector(setAccessibilityFocused:)) return (self.actions & 2) && !(self.states & (1 | 32));
    return [super isAccessibilitySelectorAllowed:selector];
}
- (NSRect)accessibilityFrame {
    NSView *view = self.bridge.view;
    if (!view) return NSZeroRect;
    NSRect r = self.logicalFrame;
    if (!view.isFlipped) r.origin.y = NSHeight(view.bounds) - NSMaxY(r);
    return NSAccessibilityFrameInView(view, r);
}
@end

static NSString *role(NSInteger code) {
    switch (code) {
    case 1: return NSAccessibilityGroupRole; // document container; children hold content
    case 2: return NSAccessibilityGroupRole;
    case 3: return NSAccessibilityStaticTextRole;
    case 4: return @"AXHeading";
    case 5: return NSAccessibilityLinkRole;
    case 6: return NSAccessibilityButtonRole;
    case 7: return NSAccessibilityCheckBoxRole;
    case 8: return NSAccessibilityTextFieldRole;
    case 9: return NSAccessibilityImageRole;
    case 10: return NSAccessibilityListRole;
    case 11: return NSAccessibilityGroupRole;
    case 12: return NSAccessibilityTableRole;
    case 13: return NSAccessibilityRowRole;
    case 14: return NSAccessibilityCellRole;
    default: return NSAccessibilityUnknownRole;
    }
}

static void invalidate(NSDictionary<NSNumber *, WAccessNode *> *nodes) {
    for (WAccessNode *n in nodes.allValues) {
        n.bridge = nil;
        n.accessibilityParent = nil;
        n.accessibilityChildren = @[];
    }
}

// All entry points must run on the AppKit main thread. The handle owns its
// view; close it before closing the window. No C-to-W callbacks are used.
void *w_access_open(void *viewPointer, intptr_t maxBytes) {
    if (!viewPointer || maxBytes < 0 || ![NSThread isMainThread]) return NULL;
    WAccessBridge *b = [WAccessBridge new];
    b.view = (__bridge NSView *)viewPointer;
    b.savedChildren = b.view.accessibilityChildren;
    b.savedElement = b.view.isAccessibilityElement;
    b.nodes = [NSMutableDictionary new];
    b.events = [NSMutableArray new];
    b.maxBytes = maxBytes;
    return (__bridge_retained void *)b;
}
void w_access_begin(void *handle) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    invalidate(b.staging);
    b.staging = [NSMutableDictionary new];
    b.stagingRoot = nil;
    b.building = YES;
    b.failed = NO;
}
intptr_t w_access_add(void *handle, intptr_t nodeID, intptr_t parentID, intptr_t roleCode, intptr_t states, intptr_t actions) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    WAccessNode *parent = b.staging[@(parentID)];
    if (!b.building || nodeID <= 0 || b.staging[@(nodeID)] || (parentID && !parent) || (!parentID && b.stagingRoot)) {
        b.failed = YES;
        return 0;
    }
    WAccessNode *n = [WAccessNode new];
    n.nodeID = nodeID;
    n.bridge = b;
    n.roleCode = roleCode;
    n.states = states | (parent.states & (1 | 32));
    n.actions = actions;
    n.accessibilityRole = role(roleCode);
    n.accessibilityIdentifier = [NSString stringWithFormat:@"w-%ld", (long)nodeID];
    n.accessibilityParent = (id)parent ?: b.view;
    n.accessibilityChildren = @[];
    if (parent) parent.accessibilityChildren = [parent.accessibilityChildren arrayByAddingObject:n];
    else b.stagingRoot = n;
    b.staging[@(nodeID)] = n;
    return 1;
}
void w_access_bounds(void *handle, intptr_t nodeID, double x, double y, double width, double height) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    b.staging[@(nodeID)].logicalFrame = NSMakeRect(x, y, width, height);
}
void w_access_heading(void *handle, intptr_t nodeID, intptr_t level) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    b.staging[@(nodeID)].heading = level;
}
intptr_t w_access_text(void *handle, intptr_t nodeID, intptr_t field, const char *data, intptr_t length) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    WAccessNode *n = b.staging[@(nodeID)];
    if (!n || length < 0 || length > b.maxBytes || (!data && length)) { b.failed = YES; return 0; }
    NSString *s = [[NSString alloc] initWithBytes:data length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    if (!s) { b.failed = YES; return 0; }
    if (field == 1) n.accessibilityLabel = s;
    else if (field == 2) n.nodeValue = s;
    else if (field == 3) n.accessibilityHelp = s;
    else { b.failed = YES; return 0; }
    return 1;
}
intptr_t w_access_commit(void *handle, intptr_t focusedID) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    if (!b.building || b.failed || !b.stagingRoot) { invalidate(b.staging); b.staging = nil; b.stagingRoot = nil; b.building = NO; return 0; }
    // Invalidate objects a client might have retained before releasing the old
    // tree, so stale native actions cannot target reused application IDs.
    invalidate(b.nodes);
    [b.events removeAllObjects];
    b.nodes = b.staging;
    b.root = b.stagingRoot;
    b.staging = nil;
    b.stagingRoot = nil;
    b.building = NO;
    b.view.accessibilityElement = NO;
    b.view.accessibilityChildren = @[b.root];
    WAccessNode *focused = b.nodes[@(focusedID)];
    if (focused.states & (1 | 32)) focused = nil;
    focused.focused = YES;
    NSAccessibilityPostNotification(b.view, NSAccessibilityLayoutChangedNotification);
    if (focused) NSAccessibilityPostNotification(focused, NSAccessibilityFocusedUIElementChangedNotification);
    b.focusedID = focusedID;
    return 1;
}
// metadata = [id, action, byte count]. Insufficient buffers do not consume the
// queued action. A zero buffer is permitted for an empty value.
intptr_t w_access_next(void *handle, intptr_t *metadata, char *buffer, intptr_t capacity) {
    WAccessBridge *b = (__bridge WAccessBridge *)handle;
    if (!b.events.count || !metadata || capacity < 0) return 0;
    NSDictionary *e = b.events[0];
    NSData *data = e[@"data"];
    metadata[0] = [e[@"id"] integerValue];
    metadata[1] = [e[@"action"] integerValue];
    metadata[2] = (intptr_t)data.length;
    if (data.length > (NSUInteger)capacity || (!buffer && data.length)) return -1;
    if (data.length) memcpy(buffer, data.bytes, data.length);
    [b.events removeObjectAtIndex:0];
    return 1;
}
void w_access_close(void *handle) {
    if (!handle) return;
    WAccessBridge *b = (__bridge_transfer WAccessBridge *)handle;
    invalidate(b.nodes);
    invalidate(b.staging);
    b.view.accessibilityChildren = b.savedChildren;
    b.view.accessibilityElement = b.savedElement;
}
