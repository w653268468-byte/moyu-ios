/* Source-script gzip adapter. MIT. Uses the system zlib, not libmobi. */
#include "include/GavinMobi.h"
#include <stdlib.h>
#include <zlib.h>

int gavin_gzip(const uint8_t *input, size_t size, int decode, uint8_t **output, size_t *output_size) {
    if (!output || !output_size || size > 2 * 1024 * 1024 || (!input && size)) return Z_STREAM_ERROR;
    *output = NULL; *output_size = 0;
    z_stream stream = {0};
    int status = decode ? inflateInit2(&stream, MAX_WBITS + 16) : deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, MAX_WBITS + 16, 8, Z_DEFAULT_STRATEGY);
    if (status != Z_OK) return status;
    size_t capacity = decode ? 4 * 1024 * 1024 : (size_t)deflateBound(&stream, (uLong)size);
    uint8_t *buffer = malloc(capacity);
    if (!buffer) { if (decode) inflateEnd(&stream); else deflateEnd(&stream); return Z_MEM_ERROR; }
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)size;
    stream.next_out = buffer; stream.avail_out = (uInt)capacity;
    status = decode ? inflate(&stream, Z_FINISH) : deflate(&stream, Z_FINISH);
    int success = status == Z_STREAM_END && stream.avail_in == 0;
    size_t written = (size_t)stream.total_out;
    if (decode) inflateEnd(&stream); else deflateEnd(&stream);
    if (!success) { free(buffer); return status == Z_STREAM_END ? Z_DATA_ERROR : status; }
    *output = buffer; *output_size = written;
    return Z_OK;
}
void gavin_buffer_free(void *buffer) { free(buffer); }
