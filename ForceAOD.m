#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>

static const NSInteger BacklightStateDim = 3;
static const NSUInteger MaximumInitializationAttempts = 30;

static id platformProvider;
static id backlightController;
static id sleepAssertion;
static NSUInteger initializationAttempts;

static CFTypeRef (*originalCopyAnswer)(CFStringRef);
static bool (*originalGetBoolAnswer)(CFStringRef);
static id (*originalTransitionInit)(id, SEL, id, id, id);
static id (*originalAlwaysOnSpecifier)(id, SEL);
static id (*originalReadPreference)(id, SEL, id);
static id (*originalSpecifierUpdates)(id, SEL, id, BOOL, BOOL);

static BOOL isAlwaysOnKey(CFStringRef key) {
    return key && CFGetTypeID(key) == CFStringGetTypeID() &&
        (CFEqual(key, CFSTR("DeviceSupportsAlwaysOnTime")) ||
         CFEqual(key, CFSTR("j8/Omm6s1lsmTDFsXjsBfA")));
}

static CFTypeRef copyAnswer(CFStringRef key) {
    return isAlwaysOnKey(key) ? CFRetain(kCFBooleanTrue) : originalCopyAnswer(key);
}

static bool getBoolAnswer(CFStringRef key) {
    return isAlwaysOnKey(key) ? true : originalGetBoolAnswer(key);
}

static BOOL alwaysSupported(__unused id object, __unused SEL selector) {
    return YES;
}

static void useLiveRendering(id transition) {
    SEL selector = NSSelectorFromString(@"setFlipbookDisabled:");
    if ([transition respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(transition, selector, YES);
    }
}

static id transitionInit(id object, SEL selector, id platform, id osProvider, id policy) {
    id transition = originalTransitionInit(object, selector, platform, osProvider, policy);
    useLiveRendering(transition);
    return transition;
}

static void acquireSleepAssertion(void) {
    if (sleepAssertion || !platformProvider) return;
    SEL selector = NSSelectorFromString(@"createPowerAssertionWithIdentifier:");
    if ([platformProvider respondsToSelector:selector]) {
        sleepAssertion = ((id (*)(id, SEL, id))objc_msgSend)(
            platformProvider, selector, @"ForceAOD.live-display");
    }
}

static void releaseSleepAssertion(void) {
    SEL selector = NSSelectorFromString(@"invalidate");
    if ([sleepAssertion respondsToSelector:selector]) {
        ((void (*)(id, SEL))objc_msgSend)(sleepAssertion, selector);
    }
    sleepAssertion = nil;
}

@interface ForceAODObserver : NSObject
@end

@implementation ForceAODObserver
- (void)backlightController:(__unused id)controller
    willTransitionToBacklightState:(NSInteger)state
                           source:(__unused NSInteger)source {
    if (state == BacklightStateDim) acquireSleepAssertion();
}

- (void)backlightController:(__unused id)controller
     didTransitionToBacklightState:(NSInteger)state
                           source:(__unused NSInteger)source {
    if (state != BacklightStateDim) releaseSleepAssertion();
}
@end

static ForceAODObserver *observer;

static void configureLiveDisplay(void) {
    Class providerClass = NSClassFromString(@"BLSHBacklightOSInterfaceProvider");
    SEL shared = NSSelectorFromString(@"sharedProvider");
    if ([providerClass respondsToSelector:shared]) {
        platformProvider = ((id (*)(id, SEL))objc_msgSend)(providerClass, shared);
    }
    Class controllerClass = NSClassFromString(@"SBBacklightController");
    SEL sharedController = NSSelectorFromString(@"sharedInstanceIfExists");
    if ([controllerClass respondsToSelector:sharedController]) {
        backlightController = ((id (*)(id, SEL))objc_msgSend)(controllerClass, sharedController);
    }
    if (!platformProvider || !backlightController) {
        if (++initializationAttempts < MaximumInitializationAttempts) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{ configureLiveDisplay(); });
        }
        return;
    }

    // Retain Apple's CoreBrightness backend; only its presentation mode changes.
    Ivar clientIvar = class_getInstanceVariable(providerClass, "_displayStateClient");
    if (!clientIvar || !object_getIvar(platformProvider, clientIvar)) return;
    Ivar delegateIvar = class_getInstanceVariable(providerClass, "_cbDisplayStateDelegate");
    id delegate = delegateIvar ? object_getIvar(platformProvider, delegateIvar) : nil;
    Ivar transitionIvar = class_getInstanceVariable([delegate class], "_delegate");
    id transition = transitionIvar ? object_getIvar(delegate, transitionIvar) : nil;
    if (!transition) return;
    useLiveRendering(transition);

    observer = [ForceAODObserver new];
    ((void (*)(id, SEL, id))objc_msgSend)(
        backlightController, NSSelectorFromString(@"addObserver:"), observer);
    NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(
        backlightController, NSSelectorFromString(@"backlightState"));
    if (state == BacklightStateDim) acquireSleepAssertion();
}

static BOOL hook(Class cls, BOOL meta, NSString *name, IMP replacement, IMP *original) {
    Class target = meta ? object_getClass(cls) : cls;
    SEL selector = NSSelectorFromString(name);
    if (!target || !class_getInstanceMethod(target, selector)) return NO;
    MSHookMessageEx(target, selector, replacement, original);
    return YES;
}

static BOOL hasMethod(Class cls, BOOL meta, NSString *name, const char *encoding) {
    Method method = class_getInstanceMethod(meta ? object_getClass(cls) : cls, NSSelectorFromString(name));
    return method && strcmp(method_getTypeEncoding(method), encoding) == 0;
}

static BOOL hasLiveDisplayInterfaces(void) {
    Class platform = NSClassFromString(@"SBBacklightPlatformProvider");
    Class provider = NSClassFromString(@"BLSHBacklightOSInterfaceProvider");
    Class controller = NSClassFromString(@"SBBacklightController");
    Class transition = NSClassFromString(@"BLSHBacklightTransitionStateMachine");
    return hasMethod(platform, YES, @"deviceSupportsAlwaysOn", "B16@0:8") &&
        hasMethod(platform, NO, @"isAlwaysOnEnabled", "B16@0:8") &&
        hasMethod(NSClassFromString(@"CBDisplayStateClient"), NO, @"supported", "B16@0:8") &&
        hasMethod(provider, YES, @"sharedProvider", "@16@0:8") &&
        hasMethod(provider, NO, @"createPowerAssertionWithIdentifier:", "@24@0:8@16") &&
        hasMethod(controller, YES, @"sharedInstanceIfExists", "@16@0:8") &&
        hasMethod(controller, NO, @"addObserver:", "v24@0:8@16") &&
        hasMethod(controller, NO, @"backlightState", "q16@0:8") &&
        hasMethod(transition, NO, @"setFlipbookDisabled:", "v20@0:8B16") &&
        hasMethod(transition, NO, @"initWithPlatformProvider:osInterfaceProvider:inactiveBudgetPolicy:", "@40@0:8@16@24@32") &&
        class_getInstanceVariable(provider, "_displayStateClient") &&
        class_getInstanceVariable(provider, "_cbDisplayStateDelegate");
}

static id alwaysOnSpecifier(id object, SEL selector) {
    id specifier = originalAlwaysOnSpecifier(object, selector);
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        specifier, NSSelectorFromString(@"setProperty:forKey:"),
        [NSNumber numberWithBool:NO], @"enabled");
    return specifier;
}

static id readPreference(id object, SEL selector, id specifier) {
    SEL property = NSSelectorFromString(@"propertyForKey:");
    id key = ((id (*)(id, SEL, id))objc_msgSend)(specifier, property, @"key");
    id domain = ((id (*)(id, SEL, id))objc_msgSend)(specifier, property, @"defaults");
    if ([key isEqual:@"SBEnableAlwaysOn"] && [domain isEqual:@"com.apple.springboard"]) {
        return [NSNumber numberWithBool:YES];
    }
    return originalReadPreference(object, selector, specifier);
}

static id specifierUpdates(id object, SEL selector, id specifiers,
                          __unused BOOL enabled, BOOL animated) {
    // Wallpaper and notification controls remain editable when the main switch is pinned.
    return originalSpecifierUpdates(object, selector, specifiers, YES, animated);
}

static BOOL configureSettings(void) {
    dlopen("/System/Library/PrivateFrameworks/Settings/"
           "DisplayAndBrightnessSettings.framework/DisplayAndBrightnessSettings", RTLD_NOW);
    Class cls = NSClassFromString(@"DBSAlwaysOnViewController");
    if (!hasMethod(cls, NO, @"_alwaysOnDisplaySpecifier", "@16@0:8") ||
        !hasMethod(cls, NO, @"readPreferenceValue:", "@24@0:8@16") ||
        !hasMethod(cls, NO, @"_updatesForSpecifiers:isAlwaysOnEnabled:animated:",
                   "@32@0:8@16B24B28")) return NO;

    hook(cls, NO, @"_alwaysOnDisplaySpecifier",
         (IMP)alwaysOnSpecifier, (IMP *)&originalAlwaysOnSpecifier);
    hook(cls, NO, @"readPreferenceValue:",
         (IMP)readPreference, (IMP *)&originalReadPreference);
    hook(cls, NO, @"_updatesForSpecifiers:isAlwaysOnEnabled:animated:",
         (IMP)specifierUpdates, (IMP *)&originalSpecifierUpdates);
    return YES;
}

__attribute__((constructor)) static void start(void) {
    @autoreleasepool {
        NSOperatingSystemVersion version = [NSProcessInfo processInfo].operatingSystemVersion;
        if (version.majorVersion < 16) return;

        NSString *bundle = [NSBundle mainBundle].bundleIdentifier;
        BOOL springBoard = [bundle isEqualToString:@"com.apple.springboard"];
        BOOL settings = [bundle isEqualToString:@"com.apple.Preferences"];
        if (!springBoard && !settings) return;

        void *gestalt = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        void *copy = gestalt ? dlsym(gestalt, "MGCopyAnswer") : NULL;
        void *boolean = gestalt ? dlsym(gestalt, "MGGetBoolAnswer") : NULL;
        if (!copy || !boolean) return;

        // Query the unmodified capability before installing either hook.
        if (((bool (*)(CFStringRef))boolean)(CFSTR("j8/Omm6s1lsmTDFsXjsBfA"))) return;
        if (settings && !configureSettings()) return;
        if (springBoard) {
            dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
            dlopen("/System/Library/PrivateFrameworks/BacklightServicesHost.framework/BacklightServicesHost", RTLD_NOW);
            if (!hasLiveDisplayInterfaces()) return;
        }

        MSHookFunction(copy, (void *)copyAnswer, (void **)&originalCopyAnswer);
        MSHookFunction(boolean, (void *)getBoolAnswer, (void **)&originalGetBoolAnswer);
        if (settings) return;

        BOOL support = hook(NSClassFromString(@"SBBacklightPlatformProvider"), YES,
            @"deviceSupportsAlwaysOn", (IMP)alwaysSupported, NULL);
        BOOL enabled = hook(NSClassFromString(@"SBBacklightPlatformProvider"), NO,
            @"isAlwaysOnEnabled", (IMP)alwaysSupported, NULL);
        BOOL client = hook(NSClassFromString(@"CBDisplayStateClient"), NO,
            @"supported", (IMP)alwaysSupported, NULL);
        BOOL transition = hook(NSClassFromString(@"BLSHBacklightTransitionStateMachine"), NO,
            @"initWithPlatformProvider:osInterfaceProvider:inactiveBudgetPolicy:",
            (IMP)transitionInit, (IMP *)&originalTransitionInit);
        if (support && enabled && client && transition) {
            dispatch_async(dispatch_get_main_queue(), ^{ configureLiveDisplay(); });
        }
    }
}
