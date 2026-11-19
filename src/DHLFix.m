// DHLFix – makes the WebView tabs (Verfolgen, Standorte) of Post & DHL 9.16.1 work on iOS 15.
// Plain dylib, injected with TrollFools. Log lines are prefixed with "[DHLFix]":
//     idevicesyslog -m '[DHLFix]'
//
// How it works
//  1. When the app loads one of DHL's SPA pages (https://www.dhl.de/int-static/pdapp/spa/…html),
//     we fetch the HTML ourselves and point every dhl.de <script src> at dhlfix://www.dhl.de/….
//     The page is then shown with -loadSimulatedRequest:, so its URL/origin stay https://www.dhl.de.
//  2. dhlfix:// is served by DHLFixSchemeHandler: it downloads the https original, lowers syntax
//     iOS 15 cannot parse (class static blocks) and hands the result to WebKit.
//  3. Because those scripts now live under dhlfix://, everything they import() – the ES module
//     bundles and their chunks – resolves to dhlfix:// as well and goes through the same handler.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DHLFixTransform.h"

#define LOG(fmt, ...) NSLog(@"[DHLFix] " fmt, ##__VA_ARGS__)

// Switches
static const BOOL kDisablePinning = NO;    // only for mitmproxy sessions
static const BOOL kLogWebViews    = YES;   // JS errors/console -> syslog (diagnostics)

static NSString *const kScheme      = @"dhlfix";
static NSString *const kHost        = @"www.dhl.de";
static NSString *const kSPAPrefix   = @"/int-static/pdapp/spa/";
static NSString *const kHandlerName = @"dhlfixlog";

#pragma mark - helpers

static IMP hookInstance(Class cls, SEL sel, id block) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { LOG(@"hook: -[%@ %@] not found", NSStringFromClass(cls), NSStringFromSelector(sel)); return NULL; }
    IMP newImp = imp_implementationWithBlock(block);
    // add to this class first so we never patch a superclass by accident
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) return method_getImplementation(m);
    return method_setImplementation(m, newImp);
}

static NSString *clip(NSString *s, NSUInteger n) {
    if (s.length <= n) return s;
    return [[s substringToIndex:n] stringByAppendingString:@"…"];
}

static BOOL isSPAPage(NSURL *url) {
    return [url.scheme isEqualToString:@"https"] && [url.host isEqualToString:kHost] &&
           [url.path hasPrefix:kSPAPrefix] && [url.path.pathExtension isEqualToString:@"html"];
}

static NSURL *httpsURLForFixURL(NSURL *url) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    c.scheme = @"https";
    return c.URL;
}

static NSURLSession *fetchSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:8 << 20
                                                     diskCapacity:64 << 20
                                                         diskPath:@"DHLFixCache"];
        cfg.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

#pragma mark - JS transform

static NSCache<NSString *, NSData *> *transformCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.totalCostLimit = 24 << 20; });
    return cache;
}

// Returns transformed JS, or the input when nothing had to change.
static NSData *fixJavaScript(NSData *data, NSString *name) {
    NSMutableData *buf = [data mutableCopy];
    [buf appendBytes:"" length:1];                       // NUL terminator for the tokenizer
    size_t outLen = 0; int count = 0;
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    char *out = dhlfix_lower_static_blocks(buf.bytes, data.length, &outLen, &count);
    if (!out) return data;
    LOG(@"lowered %d static block(s) in %@ (%.0f ms)", count, name, (CFAbsoluteTimeGetCurrent() - t0) * 1000);
    return [NSData dataWithBytesNoCopy:out length:outLen freeWhenDone:YES];
}

static BOOL looksLikeJavaScript(NSHTTPURLResponse *resp, NSURL *url) {
    NSString *type = [resp valueForHTTPHeaderField:@"Content-Type"].lowercaseString ?: @"";
    NSString *ext = url.path.pathExtension.lowercaseString;
    return [type containsString:@"javascript"] || [type containsString:@"ecmascript"] ||
           [ext isEqualToString:@"js"] || [ext isEqualToString:@"mjs"];
}

#pragma mark - dhlfix:// scheme handler

@interface DHLFixSchemeHandler : NSObject <WKURLSchemeHandler>
@property (nonatomic, strong) NSHashTable *liveTasks;   // tasks WebKit has not stopped yet
@end

@implementation DHLFixSchemeHandler

+ (instancetype)shared {
    static DHLFixSchemeHandler *h;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ h = [self new]; h.liveTasks = [NSHashTable weakObjectsHashTable]; });
    return h;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    [self.liveTasks addObject:task];
    NSURL *fixURL = task.request.URL;
    NSURL *url = httpsURLForFixURL(fixURL);
    NSString *name = url.lastPathComponent;

    NSData *cached = [transformCache() objectForKey:url.absoluteString];
    if (cached) { [self finish:task url:fixURL status:200 type:@"application/javascript" data:cached]; return; }

    NSMutableURLRequest *req = [task.request mutableCopy];
    req.URL = url;
    req.cachePolicy = NSURLRequestUseProtocolCachePolicy;
    [[fetchSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        if (error || ![http isKindOfClass:NSHTTPURLResponse.class]) {
            LOG(@"fetch failed %@: %@", url.absoluteString, error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([self.liveTasks containsObject:task]) {
                    [self.liveTasks removeObject:task];
                    [task didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
                }
            });
            return;
        }
        NSString *type = [http valueForHTTPHeaderField:@"Content-Type"] ?: @"application/octet-stream";
        NSData *body = data ?: [NSData data];
        if (http.statusCode == 200 && looksLikeJavaScript(http, url)) {
            body = fixJavaScript(body, name);
            [transformCache() setObject:body forKey:url.absoluteString cost:body.length];
            type = @"application/javascript; charset=utf-8";
        }
        [self finish:task url:fixURL status:http.statusCode type:type data:body];
    }] resume];
}

- (void)finish:(id<WKURLSchemeTask>)task url:(NSURL *)url status:(NSInteger)status type:(NSString *)type data:(NSData *)data {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.liveTasks containsObject:task]) return;
        [self.liveTasks removeObject:task];
        NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:@{
            @"Content-Type": type,
            @"Content-Length": [@(data.length) stringValue],
            @"Access-Control-Allow-Origin": @"*",
            @"Cache-Control": @"no-store",
        }];
        [task didReceiveResponse:resp];
        [task didReceiveData:data];
        [task didFinish];
    });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    [self.liveTasks removeObject:task];
}

@end

static void registerScheme(WKWebViewConfiguration *config) {
    if ([config urlSchemeHandlerForURLScheme:kScheme]) return;
    [config setURLSchemeHandler:[DHLFixSchemeHandler shared] forURLScheme:kScheme];

    // Treat dhlfix:// like https:// so an https page may load scripts from it (mixed content / CSP).
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id pool = [config valueForKey:@"processPool"];   // deprecated API, but the private calls live there
        for (NSString *sel in @[@"_registerURLSchemeAsSecure:", @"_registerURLSchemeAsBypassingContentSecurityPolicy:"]) {
            SEL s = NSSelectorFromString(sel);
            if ([pool respondsToSelector:s]) {
                ((void (*)(id, SEL, id))objc_msgSend)(pool, s, kScheme);
                LOG(@"%@ ok", sel);
            } else {
                LOG(@"%@ not available", sel);
            }
        }
    });
}

#pragma mark - SPA page rewrite

// <script ... src="https://www.dhl.de/x.js"> or src="/x.js"  ->  src="dhlfix://www.dhl.de/x.js"
static NSString *rewriteScriptSources(NSString *html, NSUInteger *count) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(<script\\b[^>]*?\\bsrc\\s*=\\s*[\"'])(?:https://www\\.dhl\\.de)?(/(?!/)[^\"'?#]*\\.m?js(?:[?#][^\"']*)?)([\"'])"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableString *out = [html mutableCopy];
    *count = [re replaceMatchesInString:out options:0 range:NSMakeRange(0, out.length)
                           withTemplate:[NSString stringWithFormat:@"$1%@://%@$2$3", kScheme, kHost]];
    return out;
}

static NSString *userAgentOf(WKWebView *wv) {
    if (wv.customUserAgent.length) return wv.customUserAgent;
    @try { return [wv valueForKey:@"_userAgent"]; } @catch (__unused id e) { return nil; }
}

// Returns YES if it took over the load.
static BOOL loadPatchedSPA(WKWebView *wv, NSURLRequest *original, WKNavigation *(^fallback)(void)) {
    if (!isSPAPage(original.URL) || ![wv respondsToSelector:@selector(loadSimulatedRequest:responseHTMLString:)]) return NO;
    registerScheme(wv.configuration);   // no-op if already there

    NSMutableURLRequest *req = [original mutableCopy];
    NSString *ua = userAgentOf(wv);
    if (ua.length) [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;   // page carries per-load Akamai tokens

    LOG(@"patching SPA %@", original.URL.absoluteString);
    __weak WKWebView *weakWV = wv;
    [[fetchSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSString *html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSUInteger n = 0;
        if (html && status == 200) html = rewriteScriptSources(html, &n);
        dispatch_async(dispatch_get_main_queue(), ^{
            WKWebView *w = weakWV;
            if (!w) return;
            if (!html || status != 200 || n == 0) {
                LOG(@"SPA fetch status=%ld err=%@ scripts=%lu -> normal load", (long)status, error.localizedDescription, (unsigned long)n);
                fallback();
                return;
            }
            LOG(@"SPA rewritten (%lu scripts via %@://)", (unsigned long)n, kScheme);
            [w loadSimulatedRequest:original responseHTMLString:html];
        });
    }] resume];
    return YES;
}

#pragma mark - JS log bridge (diagnostics)

@interface DHLFixLogHandler : NSObject <WKScriptMessageHandler>
@end

@implementation DHLFixLogHandler
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    LOG(@"JS %@", clip([message.body description], 2000));
}
@end

static NSString *const kProbeJS =
@"(function(){"
"if(window.__dhlfix)return;window.__dhlfix=1;"
"var H=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.dhlfixlog;"
"function send(t,m){try{H&&H.postMessage(t+' ['+String(location.href).slice(0,100)+'] '+m);}catch(_){}}"
"function fmt(a){try{if(typeof a==='string')return a;if(a&&a.stack)return a.message+'\\n'+a.stack;return JSON.stringify(a);}catch(_){return String(a);}}"
"window.addEventListener('error',function(e){var t=e.target;"
" if(t&&t!==window&&(t.src||t.href)){send('RESOURCE-ERROR',t.tagName+' '+(t.src||t.href));return;}"
" send('JS-ERROR',e.message+' @ '+e.filename+':'+e.lineno+':'+e.colno+(e.error&&e.error.stack?'\\n'+e.error.stack:''));},true);"
"window.addEventListener('unhandledrejection',function(e){send('REJECTION',fmt(e.reason));});"
"['error','warn'].forEach(function(k){var o=console[k];console[k]=function(){"
" try{send('CONSOLE.'+k,Array.prototype.map.call(arguments,fmt).join(' ').slice(0,1500));}catch(_){}"
" return o.apply(console,arguments);};});"
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

#pragma mark - WebKit hooks

static void hookWebKit(void) {
    Class wv = [WKWebView class];

    __block IMP origInit = hookInstance(wv, @selector(initWithFrame:configuration:),
        ^id(WKWebView *self, CGRect frame, WKWebViewConfiguration *config) {
            registerScheme(config);
            if (kLogWebViews) installProbe(config);
            return ((id (*)(id, SEL, CGRect, id))origInit)(self, @selector(initWithFrame:configuration:), frame, config);
        });

    __block IMP origLoad = hookInstance(wv, @selector(loadRequest:),
        ^WKNavigation *(WKWebView *self, NSURLRequest *req) {
            __weak WKWebView *weakSelf = self;
            WKNavigation *(^fallback)(void) = ^WKNavigation *{
                return ((id (*)(id, SEL, id))origLoad)(weakSelf, @selector(loadRequest:), req);
            };
            if (loadPatchedSPA(self, req, fallback)) return nil;
            return fallback();
        });

    // reload of a simulated load would fetch the unpatched page again
    for (NSString *name in @[@"reload", @"reloadFromOrigin"]) {
        SEL sel = NSSelectorFromString(name);
        __block IMP orig = hookInstance(wv, sel, ^WKNavigation *(WKWebView *self) {
            if (isSPAPage(self.URL)) {
                LOG(@"%@ -> patched reload", name);
                [self loadRequest:[NSURLRequest requestWithURL:self.URL]];
                return nil;
            }
            return ((id (*)(id, SEL))orig)(self, sel);
        });
    }
}

#pragma mark - TrustKit (mitmproxy only)

static void hookTrustKit(void) {
    Class v = objc_getClass("TSKPinningValidator");
    if (!v) { LOG(@"TSKPinningValidator not found"); return; }
    hookInstance(v, NSSelectorFromString(@"evaluateTrust:forHostname:"),
        ^NSInteger(id self, SecTrustRef trust, NSString *host) { return 2; });   // DomainNotPinned
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
    hookWebKit();
    if (kDisablePinning) hookTrustKit();
}
