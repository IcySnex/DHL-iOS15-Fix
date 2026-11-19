# DHL-iOS15-Fix

A small tweak for the **Post & DHL** app (`de.deutschepost.dhl`) on **iOS 15**. It fixes the web-based parts of the app that otherwise keep showing *"Bereich wird geladen … Das Laden des Bereiches dauert etwas länger"* forever:

- **Verfolgen** (the home tab with your shipments)
- **Standorte**
- **Zustellungsoption → An Packstation umleiten** (the station list and map)

It ships as a plain `arm64` dylib that you inject with [TrollFools](https://github.com/Lessica/TrollFools). No jailbreak is needed.

Tested with Post & DHL **9.16.1 (1731)**, the last version that installs on iOS 15, on an iPhone SE (1st gen) running iOS 15.8.8.

> Not affiliated with DHL or Deutsche Post. This repository contains no code from the app or from dhl.de.

## Install

1. Build `build/DHLFix.dylib` (see below) and copy it to the phone, for example with AirDrop.
2. In TrollFools, pick **Post & DHL**, inject `DHLFix.dylib` and restart the app.

## Why the app breaks on iOS 15

These tabs are web apps loaded from `www.dhl.de` into a `WKWebView`. DHL now builds their JavaScript bundles with **class static blocks** (`class X { static { … } }`), which Safari only supports since 16.4. On iOS 15, JavaScriptCore stops with `SyntaxError: Unexpected token '{'`, the module graph never loads, and the native loading screen waits forever.

A newer app version would not help: WebKit belongs to the OS, so every app version loads the same pages into the same iOS 15 engine.

[Polyfills](https://github.com/PoomSmart/Polyfills) can rewrite static blocks in classic `<script>` tags (it re-fetches them and `eval`s the fixed source). DHL loads its bundles as **ES modules via `import()`**, though. A page script can neither intercept those requests nor re-run a module with `eval`. Only native code can handle that.

## How it works

```
app loads https://www.dhl.de/…/SPA.html
        │  (hooked -[WKWebView loadRequest:])
        ▼
fetch HTML natively (WebView cookies), rewrite dhl.de <script src> to dhlfix://www.dhl.de/…,
show it with -loadSimulatedRequest: (the page keeps its https origin, cookies and API calls)
        │
        ▼
dhlfix:// is a WKURLSchemeHandler: download the https original, lower unsupported syntax,
hand it to WebKit. Every import() made by these scripts resolves to dhlfix:// as well,
so the whole module graph goes through the handler.
```

- **`src/DHLFixTransform.c`** rewrites `static { BODY }` to `static #dhlfixN = (() => { BODY })();`. The two run in the same order, and `this`/`super` still refer to the class inside the arrow function. It is a small tokenizer that understands strings, template literals, comments and regex literals, not a full parser. It needs 20–80 ms for a 2.6 MB bundle on an iPhone SE. If anything looks unbalanced, it returns the original source.
- **`src/DHLFixPage.js`** is injected into dhl.de / deutschepost.de pages. It routes scripts that a page adds later (`createElement('script')`) to `dhlfix://`, and rewrites `import()` in scripts that jQuery fetches over XHR and `eval`s. If a page that was not patched up front still throws a `SyntaxError`, it asks the native side to reload that page once through the patch path.
- The scheme is registered as secure and CSP-exempt through WebKit's private `_registerURLSchemeAsSecure:` and `_registerURLSchemeAsBypassingContentSecurityPolicy:`, so an https page may load scripts from it.

The tweak does nothing on any other site in the app (PayPal and so on).

## Build

Requirements: Xcode, [ldid](https://github.com/ProcursusTeam/ldid) and Node.js. Theos is not needed.

```bash
make            # build/DHLFix.dylib
make test       # lowers tests/static-blocks.js on the Mac and checks it behaves the same
make DEBUG=1    # also forwards JS errors/console of dhl.de pages to the syslog
```

The dylib targets `arm64` with iOS 15.0 as the minimum. TrollFools signs it on injection.

## Debugging

With the phone connected over USB ([libimobiledevice](https://libimobiledevice.org)):

```bash
idevicesyslog -m '[DHLFix]'
```

`tools/analyze.mjs` crawls a module graph from dhl.de and reports syntax that iOS 15 cannot parse:

```bash
cd tools && npm install
node analyze.mjs /tmp/dhl-modules https://www.dhl.de/int-postfinder/webservice/spa/js/standortfinder.js
```

## Limitations

- Only class static blocks are lowered, because that is all DHL uses today. If DHL starts shipping other syntax that iOS 15 lacks, the tokenizer needs another rule. `tools/analyze.mjs` shows what is new. Missing runtime APIs (`Array.prototype.toSorted` and the like) are outside the scope of this tweak; [Polyfills](https://github.com/PoomSmart/Polyfills) covers many of them on jailbroken devices.
- **Briefankündigung** still does not work on iOS 15. Newer iOS versions show a separate login sheet there, and that flow was not looked into.
- Some DHL pages scroll horizontally on 320 pt wide screens.

## License

MIT, see [LICENSE](LICENSE).
