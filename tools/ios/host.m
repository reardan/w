// Minimal UIKit host for a native W executable. No generated code, JIT,
// JavaScript, or web view: callbacks enter W ARM64 machine code.
#import <UIKit/UIKit.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern intptr_t wios_invoke(void *callback);
static void *setup_callback;
static void *lifecycle_callback;
static NSInteger app_phase;
static NSString *app_title;
static NSMutableArray<UIView *> *controls;
static UIStackView *form;

static NSString *string(const char *text) {
    return text ? ([NSString stringWithUTF8String:text] ?: @"") : @"";
}

@interface WAction : NSObject
@property(nonatomic) void *callback;
- (void)perform:(id)sender;
@end
@implementation WAction
- (void)perform:(id)sender {
    (void)sender;
    if (self.callback) wios_invoke(self.callback);
}
@end
static NSMutableArray<WAction *> *actions;

static void bind(UIControl *control, UIControlEvents event, void *callback) {
    if (!callback) return;
    WAction *action = [WAction new];
    action.callback = callback;
    [actions addObject:action];
    [control addTarget:action action:@selector(perform:) forControlEvents:event];
}

static intptr_t add(UIView *view) {
    [controls addObject:view];
    [form addArrangedSubview:view];
    return controls.count; // Stable 1-based handles; 0 is invalid.
}
static UIView *lookup(intptr_t handle) {
    if (handle <= 0 || (NSUInteger)handle > controls.count) return nil;
    return controls[handle - 1];
}

intptr_t wios_label(const char *text) {
    UILabel *label = [UILabel new];
    label.text = string(text);
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;
    return add(label);
}
void wios_label_set(intptr_t handle, const char *text) {
    UIView *view = lookup(handle);
    if ([view isKindOfClass:UILabel.class]) ((UILabel *)view).text = string(text);
}
intptr_t wios_button(const char *title, void *callback) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [button setTitle:string(title) forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    button.titleLabel.adjustsFontForContentSizeCategory = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    bind(button, UIControlEventTouchUpInside, callback);
    return add(button);
}
intptr_t wios_text_field(const char *label, void *callback) {
    UITextField *field = [UITextField new];
    field.placeholder = string(label);
    field.accessibilityLabel = string(label);
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    bind(field, UIControlEventEditingChanged, callback);
    return add(field);
}
const char *wios_text_value(intptr_t handle) {
    UIView *view = lookup(handle);
    if (![view isKindOfClass:UITextField.class]) return "";
    return ((UITextField *)view).text.UTF8String ?: "";
}
intptr_t wios_phase(void) { return app_phase; }

@interface WController : UIViewController
@end
@implementation WController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    form = [UIStackView new];
    form.axis = UILayoutConstraintAxisVertical;
    form.spacing = 20;
    form.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:form];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [form.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [form.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [form.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [form.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [form.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48],
    ]];
    controls = [NSMutableArray new];
    actions = [NSMutableArray new];
    self.title = app_title;
    if (setup_callback) wios_invoke(setup_callback);
}
@end

@interface WDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation WDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[WController new]];
    [self.window makeKeyAndVisible];
    // Deterministic simulator smoke path exercises UIKit -> W -> UIKit.
    // Normal launches never take this path.
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            for (UIView *view in controls) {
                if ([view isKindOfClass:UIButton.class]) {
                    [(UIButton *)view sendActionsForControlEvents:UIControlEventTouchUpInside];
                    break;
                }
            }
            BOOL counter_updated = NO;
            for (UIView *view in controls) {
                if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:@"1"])
                    counter_updated = YES;
                if ([view isKindOfClass:UITextField.class]) {
                    ((UITextField *)view).text = @"W × 世界";
                    [(UITextField *)view sendActionsForControlEvents:UIControlEventEditingChanged];
                }
            }
            BOOL text_updated = NO;
            for (UIView *view in controls) {
                if ([view isKindOfClass:UILabel.class] && [((UILabel *)view).text isEqualToString:@"W × 世界"])
                    text_updated = YES;
            }
            if (counter_updated && text_updated) {
                puts("ios demo UIKit: ok");
                exit(0);
            }
            fputs("ios demo UIKit: callback did not update labels\n", stderr);
            exit(1);
        });
    }
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    app_phase = 1;
    if (lifecycle_callback) wios_invoke(lifecycle_callback);
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;
    app_phase = 2;
    if (lifecycle_callback) wios_invoke(lifecycle_callback);
}
@end

intptr_t wios_run(intptr_t argc, char **argv, const char *title, void *setup, void *lifecycle) {
    @autoreleasepool {
        app_title = string(title);
        setup_callback = setup;
        lifecycle_callback = lifecycle;
        return UIApplicationMain((int)argc, argv, nil, NSStringFromClass(WDelegate.class));
    }
}
