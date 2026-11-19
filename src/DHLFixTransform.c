// Lowers ES2022 class static blocks for JavaScriptCore < 16.4 (iOS 15):
//
//     static { BODY }   ->   static #dhlfixN = (() => { BODY })();
//
// Static field initializers run in the same order as static blocks, and inside the
// arrow function `this` / `super` still refer to the class, so the semantics match.
//
// This is a small JS tokenizer (strings, template literals, comments, regex literals)
// rather than a full parser: it only has to find `static` followed by `{` and the
// matching `}`. If anything looks unbalanced it gives up and the original source is used.

#include "DHLFixTransform.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct { size_t start, end; int kind; int n; } Edit;   // kind 0 = open, 1 = close

enum { TOK_NONE, TOK_PUNCT, TOK_WORD, TOK_VALUE };   // VALUE = string/number/regex/template/keyword-like value

static int isIdent(unsigned char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           c == '_' || c == '$' || c == '#' || c == '\\' || c >= 0x80;
}

static int wordAllowsRegex(const char *w, size_t n) {
    static const char *kw[] = { "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
                                "throw", "case", "do", "else", "yield", "await", NULL };
    for (int i = 0; kw[i]; i++)
        if (strlen(kw[i]) == n && memcmp(kw[i], w, n) == 0) return 1;
    return 0;
}

static size_t skipSpaceAndComments(const char *s, size_t i, size_t len) {
    for (;;) {
        while (i < len && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r' || s[i] == '\f' || s[i] == '\v')) i++;
        if (i + 1 < len && s[i] == '/' && s[i + 1] == '/') {
            while (i < len && s[i] != '\n') i++;
        } else if (i + 1 < len && s[i] == '/' && s[i + 1] == '*') {
            const char *e = strstr(s + i + 2, "*/");   // s is NUL-terminated by the caller
            i = e ? (size_t)(e - s) + 2 : len;
        } else {
            return i;
        }
    }
}

char *dhlfix_lower_static_blocks(const char *s, size_t len, size_t *outLen, int *outCount) {
    if (outCount) *outCount = 0;
    if (!s || len == 0 || !memmem(s, len, "static", 6)) return NULL;

    // brace stack: 'B' = normal brace, 'T' = ${ in template, 'S' = static block body
    size_t cap = 256, sp = 0;
    char *stack = malloc(cap);
    int *stackBlock = malloc(cap * sizeof(int));      // static block number for 'S'
    size_t ecap = 64, ne = 0;
    Edit *edits = malloc(ecap * sizeof(Edit));
    int blocks = 0, ok = 1, prevTok = TOK_NONE;
    char prevPunct = 0;
    size_t i = 0;

#define PUSH(ch, num) do { if (sp == cap) { cap *= 2; stack = realloc(stack, cap); stackBlock = realloc(stackBlock, cap * sizeof(int)); } \
                           stack[sp] = (ch); stackBlock[sp] = (num); sp++; } while (0)
#define ADDEDIT(a, b, k, num) do { if (ne == ecap) { ecap *= 2; edits = realloc(edits, ecap * sizeof(Edit)); } \
                                   edits[ne++] = (Edit){ (a), (b), (k), (num) }; } while (0)

    // scanning a template literal body; returns 1 if it stopped at "${", 0 at closing backtick
    #define SCAN_TEMPLATE() ({ int _r = -1; \
        while (i < len) { char _c = s[i]; \
            if (_c == '\\') { i += 2; continue; } \
            if (_c == '`') { i++; _r = 0; break; } \
            if (_c == '$' && i + 1 < len && s[i + 1] == '{') { i += 2; _r = 1; break; } \
            i++; } \
        _r; })

    while (ok && i < len) {
        i = skipSpaceAndComments(s, i, len);
        if (i >= len) break;
        unsigned char c = (unsigned char)s[i];

        if (c == '"' || c == '\'') {
            char q = c; i++;
            while (i < len && s[i] != q) { if (s[i] == '\\') i++; else if (s[i] == '\n') { ok = 0; break; } i++; }
            i++; prevTok = TOK_VALUE; continue;
        }
        if (c == '`') {
            i++;
            int r = SCAN_TEMPLATE();
            if (r < 0) { ok = 0; break; }
            if (r == 1) PUSH('T', 0);
            prevTok = TOK_VALUE; continue;
        }
        if (c == '/') {
            // A regex can start after an operator/opening punctuation or a keyword like `return`
            // (keywords are recorded as TOK_PUNCT with prevPunct 0), not after a value, `)` or `]`.
            int regexAllowed = prevTok == TOK_NONE ||
                               (prevTok == TOK_PUNCT && prevPunct != ')' && prevPunct != ']');
            if (regexAllowed) {
                i++;
                int inClass = 0;
                while (i < len) {
                    char d = s[i];
                    if (d == '\\') { i += 2; continue; }
                    if (d == '\n') { ok = 0; break; }
                    if (inClass) { if (d == ']') inClass = 0; }
                    else if (d == '[') inClass = 1;
                    else if (d == '/') break;
                    i++;
                }
                i++;
                while (i < len && isIdent((unsigned char)s[i])) i++;   // flags
                prevTok = TOK_VALUE; continue;
            }
            i++; prevTok = TOK_PUNCT; prevPunct = '/'; continue;
        }
        if (isIdent(c)) {
            size_t start = i;
            while (i < len && isIdent((unsigned char)s[i])) i++;
            size_t n = i - start;
            // numbers like 1e+5 / 0x1f: fine, '+' is just punctuation afterwards
            if (n == 6 && memcmp(s + start, "static", 6) == 0 && !(prevTok == TOK_PUNCT && prevPunct == '.')) {
                size_t j = skipSpaceAndComments(s, i, len);
                if (j < len && s[j] == '{') {
                    int num = blocks++;
                    ADDEDIT(start, j + 1, 0, num);
                    PUSH('S', num);
                    i = j + 1;
                    prevTok = TOK_PUNCT; prevPunct = '{';
                    continue;
                }
            }
            prevTok = wordAllowsRegex(s + start, n) ? TOK_PUNCT : TOK_WORD;
            prevPunct = 0;   // keyword acts like an operator: regex allowed
            continue;
        }
        // punctuation
        if (c == '{') PUSH('B', 0);
        else if (c == '}') {
            if (sp == 0) { ok = 0; break; }
            char top = stack[--sp];
            if (top == 'T') {                       // end of ${ ... } -> back into the template
                i++;
                int r = SCAN_TEMPLATE();
                if (r < 0) { ok = 0; break; }
                if (r == 1) PUSH('T', 0);
                prevTok = TOK_VALUE; continue;
            }
            if (top == 'S') ADDEDIT(i, i + 1, 1, stackBlock[sp]);
        }
        prevTok = TOK_PUNCT; prevPunct = (char)c;
        i++;
    }

    char *out = NULL;
    if (ok && sp == 0 && blocks > 0) {
        // edits are already in source order (opens before their closes)
        size_t outCap = len + (size_t)blocks * 48 + 1, o = 0, pos = 0;
        out = malloc(outCap);
        for (size_t k = 0; k < ne; k++) {
            Edit e = edits[k];
            memcpy(out + o, s + pos, e.start - pos); o += e.start - pos;
            if (e.kind == 0) o += (size_t)snprintf(out + o, outCap - o, "static #dhlfix%d=(()=>{", e.n);
            else { memcpy(out + o, "})();", 5); o += 5; }
            pos = e.end;
        }
        memcpy(out + o, s + pos, len - pos); o += len - pos;
        out[o] = 0;
        if (outLen) *outLen = o;
        if (outCount) *outCount = blocks;
    }
    free(stack); free(stackBlock); free(edits);
    return out;
}
