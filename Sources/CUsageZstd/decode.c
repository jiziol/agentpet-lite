#include "include/UsageZstd.h"
#include "lib/zstd.h"
#include <stdlib.h>
#include <string.h>

int usage_zstd_decode(const void *input, size_t length, size_t limit,
                      void **output, size_t *output_length) {
    *output = NULL; *output_length = 0;
    ZSTD_DCtx *ctx = ZSTD_createDCtx();
    if (!ctx) return -2;
    ZSTD_DCtx_setParameter(ctx, ZSTD_d_windowLogMax, 27);
    size_t capacity = limit < 131072 ? limit : 131072, used = 0, remaining = 1;
    char *buffer = malloc(capacity);
    if (!buffer) { ZSTD_freeDCtx(ctx); return -2; }
    ZSTD_inBuffer src = { input, length, 0 };
    int status = 0, drain = 0;
    while (src.pos < src.size || drain) {
        if (used == capacity) {
            if (capacity >= limit) { status = -2; break; }
            size_t next = capacity > limit / 2 ? limit : capacity * 2;
            char *grown = realloc(buffer, next);
            if (!grown) { status = -2; break; }
            buffer = grown; capacity = next;
        }
        ZSTD_outBuffer dst = { buffer + used, capacity - used, 0 };
        size_t before = src.pos;
        remaining = ZSTD_decompressStream(ctx, &dst, &src);
        if (ZSTD_isError(remaining)) { status = -1; break; }
        used += dst.pos;
        drain = remaining != 0 && dst.pos == dst.size;
        if (before == src.pos && dst.pos == 0) {
            if (src.pos == src.size) break;
            status = -1; break;
        }
    }
    ZSTD_freeDCtx(ctx);
    if (status < 0) { free(buffer); return status; }
    *output = buffer; *output_length = used;
    return remaining == 0 ? 0 : 1;
}
void usage_zstd_free(void *output) { free(output); }
