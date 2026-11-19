// DHLFix – diagnostic + fix tweak for Post & DHL 9.16.1 on iOS 15.
// Plain dylib, injected with TrollFools. All log lines are prefixed with "[DHLFix]"
// so they can be filtered with: idevicesyslog -m '[DHLFix]'

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

#define LOG(fmt, ...) NSLog(@"[DHLFix] " fmt, ##__VA_ARGS__)

// Diagnostic switches
static const BOOL kDisablePinning = YES;   // lets mitmproxy see native traffic
static const BOOL kLogWebViews    = YES;   // JS errors, console, loads -> syslog

static NSString *const kHandlerName = @"dhlfixlog";

#pragma mark - helpers

static IMP hookInstance(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LOG(@"hook: %@ -[%@] not found", NSStringFromClass(cls), NSStringFromSelector(sel)); return NULL; }
    IMP newImp = imp_implementationWithBlock(block);
    // add to this class first so we never patch a superclass by accident
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) return method_getImplementation(m);
    return method_setImplementation(m, newImp);
}

static NSString *clip(NSString *s, NSUInteger n) {
    if (s.length <= n) return s;
    return [[s substringToIndex:n] stringByAppendingString:@"…"];
}

#pragma mark - JS log bridge

@interface DHLFixLogHandler : NSObject <WKScriptMessageHandler>
@end

@implementation DHLFixLogHandler
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    LOG(@"JS %@", clip([message.body description], 3000));
}
@end

static NSString *const kProbeJS =
@"(function(){"
"if(window.__dhlfix)return;window.__dhlfix=1;"
"var H=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.dhlfixlog;"
"function send(t,m){try{H&&H.postMessage(t+' ['+String(location.href).slice(0,140)+'] '+m);}catch(_){}}"
"function fmt(a){try{if(typeof a==='string')return a;if(a&&a.stack)return a.message+'\\n'+a.stack;return JSON.stringify(a);}catch(_){return String(a);}}"
"window.addEventListener('error',function(e){var t=e.target;"
" if(t&&t!==window&&(t.src||t.href)){send('RESOURCE-ERROR',t.tagName+' '+(t.src||t.href));return;}"
" send('JS-ERROR',e.message+' @ '+e.filename+':'+e.lineno+':'+e.colno+(e.error&&e.error.stack?'\\n'+e.error.stack:''));},true);"
"window.addEventListener('unhandledrejection',function(e){send('REJECTION',fmt(e.reason));});"
"['error','warn','log','info'].forEach(function(k){var o=console[k];console[k]=function(){"
" try{send('CONSOLE.'+k,Array.prototype.map.call(arguments,fmt).join(' ').slice(0,2000));}catch(_){}"
" return o.apply(console,arguments);};});"
"send('DOC-START',document.readyState);"
"document.addEventListener('DOMContentLoaded',function(){send('DOMContentLoaded','');});"
"window.addEventListener('load',function(){send('LOAD',document.scripts.length+' scripts');});"
"})();";

static void installProbe(WKWebViewConfiguration *config) {
    WKUserContentController *ucc = config.userContentController;
    if (!ucc || objc_getAssociatedObject(ucc, &kHandlerName)) return;
    objc_setAssociatedObject(ucc, &kHandlerName, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ucc addScriptMessageHandler:[DHLFixLogHandler new] name:kHandlerName];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:kProbeJS
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO]];
}

static void hookWebKit(void) {
    Class wv = [WKWebView class];

    __block IMP origInit = hookInstance(wv, @selector(initWithFrame:configuration:),
        ^id(WKWebView *self, CGRect frame, WKWebViewConfiguration *config) {
            installProbe(config);
            return ((id (*)(id, SEL, CGRect, id))origInit)(self, @selector(initWithFrame:configuration:), frame, config);
        });

    __block IMP origLoad = hookInstance(wv, @selector(loadRequest:),
        ^WKNavigation *(WKWebView *self, NSURLRequest *req) {
            LOG(@"loadRequest %@", req.URL.absoluteString);
            return ((id (*)(id, SEL, id))origLoad)(self, @selector(loadRequest:), req);
        });

    __block IMP origHTML = hookInstance(wv, @selector(loadHTMLString:baseURL:),
        ^WKNavigation *(WKWebView *self, NSString *html, NSURL *base) {
            LOG(@"loadHTMLString base=%@ len=%lu head=%@", base.absoluteString, (unsigned long)html.length, clip(html, 300));
            return ((id (*)(id, SEL, id, id))origHTML)(self, @selector(loadHTMLString:baseURL:), html, base);
        });

    __block IMP origFile = hookInstance(wv, @selector(loadFileURL:allowingReadAccessToURL:),
        ^WKNavigation *(WKWebView *self, NSURL *url, NSURL *access) {
            LOG(@"loadFileURL %@", url.path);
            return ((id (*)(id, SEL, id, id))origFile)(self, @selector(loadFileURL:allowingReadAccessToURL:), url, access);
        });

    __block IMP origEval = hookInstance(wv, @selector(evaluateJavaScript:completionHandler:),
        ^(WKWebView *self, NSString *js, void (^completion)(id, NSError *)) {
            LOG(@"evaluateJavaScript %@", clip(js, 400));
            ((void (*)(id, SEL, id, id))origEval)(self, @selector(evaluateJavaScript:completionHandler:), js,
                ^(id result, NSError *error) {
                    if (error) LOG(@"evaluateJavaScript error %@", error.localizedDescription);
                    if (completion) completion(result, error);
                });
        });

    Class ucc = [WKUserContentController class];
    __block IMP origAddHandler = hookInstance(ucc, @selector(addScriptMessageHandler:name:),
        ^(WKUserContentController *self, id handler, NSString *name) {
            if (![name isEqualToString:kHandlerName]) LOG(@"app registers JS handler '%@' (%@)", name, NSStringFromClass([handler class]));
            ((void (*)(id, SEL, id, id))origAddHandler)(self, @selector(addScriptMessageHandler:name:), handler, name);
        });

    __block IMP origAddScript = hookInstance(ucc, @selector(addUserScript:),
        ^(WKUserContentController *self, WKUserScript *script) {
            if (![script.source isEqualToString:kProbeJS]) LOG(@"app adds user script: %@", clip(script.source, 400));
            ((void (*)(id, SEL, id))origAddScript)(self, @selector(addUserScript:), script);
        });
}

#pragma mark - TrustKit

static void hookTrustKit(void) {
    Class v = objc_getClass("TSKPinningValidator");
    if (!v) { LOG(@"TSKPinningValidator not found"); return; }
    // TSKTrustDecisionDomainNotPinned == 2
    hookInstance(v, NSSelectorFromString(@"evaluateTrust:forHostname:"),
        ^NSInteger(id self, SecTrustRef trust, NSString *host) { return 2; });
    hookInstance(v, NSSelectorFromString(@"handleChallenge:completionHandler:"),
        ^BOOL(id self, NSURLAuthenticationChallenge *ch, void (^completion)(NSURLSessionAuthChallengeDisposition, NSURLCredential *)) {
            completion(NSURLSessionAuthChallengePerformDefaultHandling, nil);
            return YES;
        });
    LOG(@"pinning disabled");
}

__attribute__((constructor)) static void DHLFixInit(void) {
    LOG(@"loaded into %@ %@", NSBundle.mainBundle.bundleIdentifier,
        [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
    if (kLogWebViews) hookWebKit();
    if (kDisablePinning) hookTrustKit();
}
