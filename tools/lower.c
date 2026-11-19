// macOS test driver: lower.c <in.js> <out.js>
#include "../src/DHLFixTransform.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    FILE *f = fopen(argv[1], "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
    char *s = malloc(n + 1); fread(s, 1, n, f); s[n] = 0; fclose(f);
    size_t outLen = 0; int count = 0;
    char *out = dhlfix_lower_static_blocks(s, n, &outLen, &count);
    FILE *o = fopen(argv[2], "wb"); fwrite(out ? out : s, 1, out ? outLen : n, o); fclose(o);
    printf("%d static blocks lowered%s\n", count, out ? "" : " (unchanged)");
    return 0;
}
