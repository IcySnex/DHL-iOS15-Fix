#pragma once
#include <stddef.h>

// Returns a malloc'd, NUL-terminated copy of `src` with class static blocks lowered,
// or NULL when there is nothing to change or the source could not be tokenized safely.
// `src` must be NUL-terminated (len excludes the terminator).
char *dhlfix_lower_static_blocks(const char *src, size_t len, size_t *outLen, int *outCount);
