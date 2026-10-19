/* Gavin adapter. Application code: MIT. libmobi remains LGPL-3.0-or-later. */
#include "include/GavinMobi.h"
#include "Vendor/mobi.h"
#include <stdlib.h>
#include <string.h>

struct GavinMobi {
    MOBIData *source;
    MOBIRawml *raw;
    MOBIPart **parts;
    char (*names)[64];
    size_t count;
};
void gavin_mobi_close(GavinMobi *book) {
    if (!book) return;
    if (book->raw) mobi_free_rawml(book->raw);
    if (book->source) mobi_free(book->source);
    free(book->parts); free(book->names); free(book);
}
GavinMobi *gavin_mobi_open(const uint8_t *bytes, size_t size, int *error) {
    *error = MOBI_DATA_CORRUPT;
    if (!bytes || size < 78 || size > 100 * 1024 * 1024) return NULL;
    GavinMobi *book = calloc(1, sizeof(*book));
    if (!book) { *error = MOBI_MALLOC_FAILED; return NULL; }
    book->source = mobi_init();
    FILE *file = tmpfile();
    if (!file || !book->source) {
        if (file) fclose(file);
        *error = MOBI_INIT_FAILED; gavin_mobi_close(book); return NULL;
    }
    if (fwrite(bytes, 1, size, file) != size || fseek(file, 0, SEEK_SET)) {
        fclose(file); *error = MOBI_WRITE_FAILED; gavin_mobi_close(book); return NULL;
    }
    MOBI_RET result = mobi_load_file(book->source, file);
    fclose(file);
    if (result != MOBI_SUCCESS) { *error = result; gavin_mobi_close(book); return NULL; }
    if (mobi_is_encrypted(book->source)) { *error = MOBI_FILE_ENCRYPTED; gavin_mobi_close(book); return NULL; }
    size_t maximum = mobi_get_text_maxsize(book->source);
    if (!maximum || maximum > 40 * 1024 * 1024) { *error = 1001; gavin_mobi_close(book); return NULL; }
    book->raw = mobi_init_rawml(book->source);
    if (!book->raw) { *error = MOBI_MALLOC_FAILED; gavin_mobi_close(book); return NULL; }
    result = mobi_parse_rawml(book->raw, book->source);
    if (result != MOBI_SUCCESS) { *error = result; gavin_mobi_close(book); return NULL; }
    MOBIPart *lists[] = { book->raw->markup, book->raw->flow ? book->raw->flow->next : NULL, book->raw->resources };
    size_t count = 0, total = 0;
    for (size_t group = 0; group < 3; group++) {
        for (MOBIPart *part = lists[group]; part; part = part->next) {
            if (++count > 20000 || part->size > 40 * 1024 * 1024 || part->size > 200 * 1024 * 1024 - total) {
                *error = 1001; gavin_mobi_close(book); return NULL;
            }
            total += part->size;
        }
    }
    if (!count) { gavin_mobi_close(book); return NULL; }
    book->parts = calloc(count, sizeof(*book->parts)); book->names = calloc(count, sizeof(*book->names));
    if (!book->parts || !book->names) { *error = MOBI_MALLOC_FAILED; gavin_mobi_close(book); return NULL; }
    const char *prefixes[] = { "part", "flow", "resource" };
    for (size_t group = 0; group < 3; group++) {
        for (MOBIPart *part = lists[group]; part; part = part->next) {
            if (!part->size || !part->data) continue;
            MOBIFileMeta meta = mobi_get_filemeta_by_type(part->type);
            const char *ext = meta.extension;
            if (!ext || !*ext || strlen(ext) > 12 || strspn(ext, "abcdefghijklmnopqrstuvwxyz0123456789") != strlen(ext)) {
                *error = MOBI_FILE_UNSUPPORTED; gavin_mobi_close(book); return NULL;
            }
            book->parts[book->count] = part;
            if (part->type == T_OPF) snprintf(book->names[book->count], 64, "OEBPS/content.opf");
            else snprintf(book->names[book->count], 64, "OEBPS/%s%05zu.%s", prefixes[group], part->uid, ext);
            book->count++;
        }
    }
    *error = 0;
    return book;
}
size_t gavin_mobi_count(const GavinMobi *book) { return book ? book->count : 0; }
const char *gavin_mobi_name(const GavinMobi *book, size_t index) { return book && index < book->count ? book->names[index] : NULL; }
const uint8_t *gavin_mobi_data(const GavinMobi *book, size_t index) { return book && index < book->count ? book->parts[index]->data : NULL; }
size_t gavin_mobi_size(const GavinMobi *book, size_t index) { return book && index < book->count ? book->parts[index]->size : 0; }
