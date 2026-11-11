#ifndef AGENTPET_USAGE_ZSTD_H
#define AGENTPET_USAGE_ZSTD_H
#include <stddef.h>
/* 0: complete, 1: incomplete final frame, -1: corrupt, -2: size/window bound.
   Caller owns output and frees it with usage_zstd_free. Never launches a tool. */
int usage_zstd_decode(const void *input, size_t length, size_t limit,
                      void **output, size_t *output_length);
void usage_zstd_free(void *output);
#endif
