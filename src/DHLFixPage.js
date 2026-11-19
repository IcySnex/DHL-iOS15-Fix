// Injected at document start into every frame of every WKWebView in the app.
// Only does something on dhl.de / deutschepost.de pages.
//  - dhl.de scripts that get added later are routed through dhlfix:// as well:
//    createElement('script') via the src setter, XHR + eval (jQuery $.load()) via import() rewriting.
//  - if a page that was NOT patched natively still hits a SyntaxError, ask native to
//    reload it once through the patch path (self-healing for pages we do not know about).
(function () {
  if (window.__dhlfixPage) return;
  window.__dhlfixPage = 1;

  var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.dhlfix;
  var LOG = __DHLFIX_LOG__;
  function post(msg) { try { bridge && bridge.postMessage(msg); } catch (_) {} }
  function log(t, m) { if (LOG) post({ t: 'log', m: t + ' [' + String(location.href).slice(0, 100) + '] ' + m }); }

  function fixHost(h) { return /(^|\.)(dhl|deutschepost)\.de$/i.test(h || ''); }
  if (!fixHost(location.hostname)) return;

  function toFix(u, base) {
    try {
      var x = new URL(u, base || document.baseURI);
      if (x.protocol === 'https:' && fixHost(x.hostname) && /\.m?js$/i.test(x.pathname))
        return 'dhlfix://' + x.host + x.pathname + x.search;
    } catch (_) {}
    return null;
  }

  // 1. dynamically created <script src>
  var srcDesc = Object.getOwnPropertyDescriptor(HTMLScriptElement.prototype, 'src');
  if (srcDesc && srcDesc.set) {
    Object.defineProperty(HTMLScriptElement.prototype, 'src', {
      configurable: true, enumerable: srcDesc.enumerable, get: srcDesc.get,
      set: function (v) {
        var f = toFix(v);
        if (f) log('SCRIPT', v);
        srcDesc.set.call(this, f || v);
      }
    });
  }
  var setAttr = Element.prototype.setAttribute;
  Element.prototype.setAttribute = function (name, value) {
    if (this.tagName === 'SCRIPT' && String(name).toLowerCase() === 'src') {
      var f = toFix(value);
      if (f) { log('SCRIPT', value); value = f; }
    }
    return setAttr.call(this, name, value);
  };

  // 2. Scripts fetched with XHR and eval'd (jQuery runs <script src> of $.load() fragments that way,
  //    synchronously). Eval'd code resolves import() against the https page, so its import() calls
  //    are rewritten to __dhlfixImport(), which loads the module graph via dhlfix:// instead.
  window.__dhlfixImport = function (spec) {
    var target = String(spec);
    try {
      var u = new URL(target, document.baseURI);
      target = (u.protocol === 'https:' && fixHost(u.hostname)) ? 'dhlfix://' + u.host + u.pathname + u.search : u.href;
    } catch (_) {}
    log('IMPORT', spec + ' -> ' + target);
    return import(target);
  };
  var DYN_IMPORT = /(^|[^.\w$])import\s*\(/g;
  function rewriteJS(code) { return code.replace(DYN_IMPORT, '$1__dhlfixImport('); }
  var xhrOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__dhlfixUrl = url;
    this.__dhlfixText = undefined;
    return xhrOpen.apply(this, arguments);
  };
  var rtDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseText');
  if (rtDesc && rtDesc.get) {
    Object.defineProperty(XMLHttpRequest.prototype, 'responseText', {
      configurable: true, enumerable: rtDesc.enumerable,
      get: function () {
        var text = rtDesc.get.call(this);
        if (this.readyState !== 4 || !text || this.__dhlfixUrl == null) return text;
        if (this.__dhlfixText !== undefined) return this.__dhlfixText;
        var out = text;
        try {
          var url = new URL(this.__dhlfixUrl, document.baseURI);
          var type = this.getResponseHeader('content-type') || '';
          var isJS = /javascript|ecmascript/i.test(type) || /\.m?js$/i.test(url.pathname);
          if (isJS && fixHost(url.hostname) && text.indexOf('import') !== -1) {
            out = rewriteJS(text);
            if (out !== text) log('XHR-JS', url.href);
          }
        } catch (_) {}
        this.__dhlfixText = out;
        return out;
      }
    });
  }

  // 3. self-healing for pages that were not patched natively
  var SYNTAX = /SyntaxError|Unexpected token|Unexpected identifier|Unexpected keyword|Unexpected private name|Invalid regular expression/;
  function check(msg) {
    msg = String(msg || '');
    if (!SYNTAX.test(msg)) return;
    if (window !== window.top || window.__dhlfixPatched) return;
    try {
      var key = 'dhlfix-repatch:' + location.href;
      if (sessionStorage.getItem(key)) return;
      sessionStorage.setItem(key, '1');
    } catch (_) {}
    post({ t: 'repatch', url: location.href, why: msg.slice(0, 200) });
  }
  function fmt(a) {
    try { if (typeof a === 'string') return a; if (a && a.stack) return a.message + '\n' + a.stack; return JSON.stringify(a); }
    catch (_) { return String(a); }
  }

  window.addEventListener('error', function (e) {
    var t = e.target;
    if (t && t !== window && (t.src || t.href)) { log('RESOURCE-ERROR', t.tagName + ' ' + (t.src || t.href)); return; }
    var m = e.message + ' @ ' + e.filename + ':' + e.lineno + ':' + e.colno;
    log('JS-ERROR', m + (e.error && e.error.stack ? '\n' + e.error.stack : ''));
    check(m);
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var m = fmt(e.reason);
    log('REJECTION', m);
    check(m);
  });
  ['error', 'warn'].forEach(function (k) {
    var orig = console[k];
    console[k] = function () {
      try {
        var m = Array.prototype.map.call(arguments, fmt).join(' ');
        log('CONSOLE.' + k, m.slice(0, 1500));
        if (k === 'error') check(m);
      } catch (_) {}
      return orig.apply(console, arguments);
    };
  });
  if (LOG) window.addEventListener('load', function () { log('LOAD', (window.__dhlfixPatched ? 'patched, ' : '') + document.scripts.length + ' scripts'); });
})();
