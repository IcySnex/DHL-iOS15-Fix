// DHLFix – makes the WebView parts of Post & DHL 9.16.1 (Verfolgen, Standorte, Packstation-Umleitung, …)
// work on iOS 15. Plain dylib, injected with TrollFools. Log lines are prefixed with "[DHLFix]":
//     idevicesyslog -m '[DHLFix]'
//
// DHL's web bundles use JavaScript syntax that iOS 15 cannot parse (class static blocks).
// They are ES modules loaded with import(), so they cannot be patched from inside the page.
// Instead every dhl.de script is routed through a custom URL scheme handled in the app:
//
//  1. Page:   when a dhl.de page is loaded we fetch its HTML ourselves, point every dhl.de
//             <script src> at dhlfix://<host>/… and show it with -loadSimulatedRequest:, so the
//             page keeps its https origin, cookies and API calls.
//             Known SPA pages are patched up front; any other dhl.de page is patched once it
//             reports a SyntaxError (DHLFixPage.js asks for it).
//  2. Scheme: dhlfix:// is served by DHLFixSchemeHandler: it downloads the https original, lowers
//             the unsupported syntax and hands the result to WebKit.
//  3. Graph:  scripts living under dhlfix:// resolve their import()s – the ES module bundles and
//             chunks – to dhlfix:// too. Scripts added later (jQuery fragments, createElement)
//             are redirected by DHLFixPage.js.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "DHLFixTransform.h"
#import "DHLFixPage.h"   // generated from DHLFixPage.js: kDHLFixPageJS

#define LOG(fmt, ...) NSLog(@"[DHLFix] " fmt, ##__VA_ARGS__)

// Switches
static const BOOL kDisablePinning = NO;    // only for mitmproxy sessions
static const BOOL kLogWebViews    = YES;   // JS errors/console -> syslog (diagnostics)

static NSString *const kScheme      = @"dhlfix";
static NSString *const kSPAPrefix   = @"/int-static/pdapp/spa/";
static NSString *const kHandlerName = @"dhlfix";

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

static BOOL isFixHost(NSString *host) {
    host = host.lowercaseString;
    for (NSString *d in @[@"dhl.de", @"deutschepost.de"])
        if ([host isEqualToString:d] || [host hasSuffix:[@"." stringByAppendingString:d]]) return YES;
    return NO;
}

static BOOL isFixPage(NSURL *url) {
    return [url.scheme isEqualToString:@"https"] && isFixHost(url.host);
}

static BOOL isKnownSPAPage(NSURL *url) {
    return isFixPage(url) && [url.path hasPrefix:kSPAPrefix] && [url.path.pathExtension isEqualToString:@"html"];
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
        cfg.HTTPShouldSetCookies = NO;       // page loads carry the WebView's cookies explicitly
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
@property (nonatomic, strong) NSHashTable *liveTasks;   // tasks WebKit has not stopped yet (main thread only)
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
                if (![self.liveTasks containsObject:task]) return;
                [self.liveTasks removeObject:task];
                [task didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
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

#pragma mark - page rewrite

// Points every dhl.de <script src="….js"> (absolute, root-relative or relative) at dhlfix://
// and marks the page as patched for DHLFixPage.js.
static NSString *rewritePage(NSString *html, NSURL *pageURL, NSUInteger *count) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"(<script\\b[^>]*?\\bsrc\\s*=\\s*[\"'])([^\"']+)([\"'])"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSMutableString *out = [html mutableCopy];
    NSArray<NSTextCheckingResult *> *matches = [re matchesInString:html options:0 range:NSMakeRange(0, html.length)];
    NSUInteger n = 0;
    for (NSTextCheckingResult *m in matches.reverseObjectEnumerator) {
        NSString *src = [[html substringWithRange:[m rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
        NSURL *abs = [NSURL URLWithString:src relativeToURL:pageURL].absoluteURL;
        NSString *ext = abs.path.pathExtension.lowercaseString;
        if (!isFixPage(abs) || !([ext isEqualToString:@"js"] || [ext isEqualToString:@"mjs"])) continue;
        NSURLComponents *c = [NSURLComponents componentsWithURL:abs resolvingAgainstBaseURL:NO];
        c.scheme = kScheme;
        [out replaceCharactersInRange:[m rangeAtIndex:2] withString:c.URL.absoluteString];
        n++;
    }
    if (n) {
        NSString *marker = @"<script>window.__dhlfixPatched=1</script>";
        NSRange head = [out rangeOfString:@"<head>" options:NSCaseInsensitiveSearch];
        [out insertString:marker atIndex:head.location != NSNotFound ? NSMaxRange(head) : 0];
    }
    *count = n;
    return out;
}

static NSString *userAgentOf(WKWebView *wv) {
    if (wv.customUserAgent.length) return wv.customUserAgent;
    @try { return [wv valueForKey:@"_userAgent"]; } @catch (__unused id e) { return nil; }
}

static BOOL cookieMatches(NSHTTPCookie *c, NSURL *url) {
    NSString *host = url.host.lowercaseString, *domain = c.domain.lowercaseString;
    BOOL domainOK = [domain hasPrefix:@"."] ? ([host hasSuffix:domain] || [host isEqualToString:[domain substringFromIndex:1]])
                                            : [host isEqualToString:domain];
    NSString *path = url.path.length ? url.path : @"/";
    return domainOK && [path hasPrefix:c.path ?: @"/"] && !(c.expiresDate && c.expiresDate.timeIntervalSinceNow < 0);
}

// Fetches `request` with the WebView's cookies, rewrites the scripts and shows it with
// -loadSimulatedRequest:. Calls `fallback` (on main) when the page cannot be patched.
static void loadPatchedPage(WKWebView *wv, NSURLRequest *request, NSString *reason, void (^fallback)(void)) {
    registerScheme(wv.configuration);   // no-op if already there
    __weak WKWebView *weakWV = wv;
    WKHTTPCookieStore *store = wv.configuration.websiteDataStore.httpCookieStore;

    [store getAllCookies:^(NSArray<NSHTTPCookie *> *all) {
        WKWebView *w0 = weakWV;
        if (!w0) return;
        NSMutableURLRequest *req = [request mutableCopy];
        NSString *ua = userAgentOf(w0);
        if (ua.length) [req setValue:ua forHTTPHeaderField:@"User-Agent"];
        NSArray *cookies = [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSHTTPCookie *c, id _) {
            return cookieMatches(c, request.URL);
        }]];
        [[NSHTTPCookie requestHeaderFieldsWithCookies:cookies] enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
            [req setValue:v forHTTPHeaderField:k];
        }];
        req.HTTPShouldHandleCookies = NO;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;   // pages carry per-load Akamai tokens

        LOG(@"patching page (%@) %@", reason, request.URL.absoluteString);
        [[fetchSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSInteger status = [http isKindOfClass:NSHTTPURLResponse.class] ? http.statusCode : 0;
            NSString *type = [http valueForHTTPHeaderField:@"Content-Type"] ?: @"";
            BOOL redirected = http.URL && ![http.URL.absoluteString isEqualToString:request.URL.absoluteString];
            NSString *html = (status == 200 && [type containsString:@"html"] && !redirected && data)
                ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
            NSUInteger n = 0;
            if (html) html = rewritePage(html, request.URL, &n);
            NSArray<NSHTTPCookie *> *setCookies = http ? [NSHTTPCookie cookiesWithResponseHeaderFields:http.allHeaderFields forURL:request.URL] : @[];

            dispatch_async(dispatch_get_main_queue(), ^{
                WKWebView *w = weakWV;
                if (!w) return;
                if (!html || n == 0) {
                    LOG(@"not patched: status=%ld type=%@ redirected=%d scripts=%lu err=%@",
                        (long)status, type, redirected, (unsigned long)n, error.localizedDescription);
                    if (fallback) fallback();
                    return;
                }
                // keep cookies the page response set, then show the patched page
                dispatch_group_t g = dispatch_group_create();
                for (NSHTTPCookie *c in setCookies) { dispatch_group_enter(g); [store setCookie:c completionHandler:^{ dispatch_group_leave(g); }]; }
                dispatch_group_notify(g, dispatch_get_main_queue(), ^{
                    LOG(@"page rewritten (%lu scripts via %@://)", (unsigned long)n, kScheme);
                    [w loadSimulatedRequest:request responseHTMLString:html];
                });
            });
        }] resume];
    }];
}

#pragma mark - page script bridge

@interface DHLFixPageHandler : NSObject <WKScriptMessageHandler>
@end

@implementation DHLFixPageHandler
- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSString *t = body[@"t"];
    if ([t isEqualToString:@"log"]) {
        LOG(@"JS %@", clip([body[@"m"] description], 2000));
    } else if ([t isEqualToString:@"repatch"]) {
        WKWebView *wv = message.webView;
        NSURL *url = [NSURL URLWithString:body[@"url"]];
        if (!wv || !isFixPage(url) || !message.frameInfo.isMainFrame) return;
        LOG(@"repatch requested: %@", clip(body[@"why"], 200));
        loadPatchedPage(wv, [NSURLRequest requestWithURL:url], @"syntax error", nil);
    }
}
@end

static void installPageScript(WKWebViewConfiguration *config) {
    WKUserContentController *ucc = config.userContentController;
    if (!ucc || objc_getAssociatedObject(ucc, &kHandlerName)) return;
    objc_setAssociatedObject(ucc, &kHandlerName, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *js = [[NSString stringWithUTF8String:kDHLFixPageJS]
                    stringByReplacingOccurrencesOfString:@"__DHLFIX_LOG__" withString:kLogWebViews ? @"true" : @"false"];
    [ucc addScriptMessageHandler:[DHLFixPageHandler new] name:kHandlerName];
    [ucc addUserScript:[[WKUserScript alloc] initWithSource:js
                                              injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                           forMainFrameOnly:NO]];
}

#pragma mark - WebKit hooks

static void hookWebKit(void) {
    Class wv = [WKWebView class];

    __block IMP origInit = hookInstance(wv, @selector(initWithFrame:configuration:),
        ^id(WKWebView *self, CGRect frame, WKWebViewConfiguration *config) {
            registerScheme(config);
            installPageScript(config);
            return ((id (*)(id, SEL, CGRect, id))origInit)(self, @selector(initWithFrame:configuration:), frame, config);
        });

    __block IMP origLoad = hookInstance(wv, @selector(loadRequest:),
        ^WKNavigation *(WKWebView *self, NSURLRequest *req) {
            BOOL plainGET = (!req.HTTPMethod || [req.HTTPMethod isEqualToString:@"GET"]) && !req.HTTPBody && !req.HTTPBodyStream;
            if (plainGET && isKnownSPAPage(req.URL) && [self respondsToSelector:@selector(loadSimulatedRequest:responseHTMLString:)]) {
                __weak WKWebView *weakSelf = self;
                loadPatchedPage(self, req, @"spa", ^{ ((id (*)(id, SEL, id))origLoad)(weakSelf, @selector(loadRequest:), req); });
                return nil;
            }
            return ((id (*)(id, SEL, id))origLoad)(self, @selector(loadRequest:), req);
        });

    // reload of a simulated load would fetch the unpatched page again
    for (NSString *name in @[@"reload", @"reloadFromOrigin"]) {
        SEL sel = NSSelectorFromString(name);
        __block IMP orig = hookInstance(wv, sel, ^WKNavigation *(WKWebView *self) {
            if (isKnownSPAPage(self.URL)) {
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
