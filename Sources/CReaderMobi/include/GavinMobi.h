#ifndef GAVIN_MOBI_H
#define GAVIN_MOBI_H
#include <stddef.h>
#include <stdint.h>
typedef struct GavinMobi GavinMobi;
GavinMobi *gavin_mobi_open(const uint8_t *bytes, size_t size, int *error);
void gavin_mobi_close(GavinMobi *book);
size_t gavin_mobi_count(const GavinMobi *book);
const char *gavin_mobi_name(const GavinMobi *book, size_t index);
const uint8_t *gavin_mobi_data(const GavinMobi *book, size_t index);
size_t gavin_mobi_size(const GavinMobi *book, size_t index);
int gavin_gzip(const uint8_t *input, size_t size, int decode, uint8_t **output, size_t *output_size);
void gavin_buffer_free(void *buffer);
#endif
