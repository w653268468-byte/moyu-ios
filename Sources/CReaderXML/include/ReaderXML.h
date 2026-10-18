#ifndef GAVIN_READER_XML_H
#define GAVIN_READER_XML_H
typedef struct {
    char **values;
    int count;
    char *error;
} GavinXPathResult;
GavinXPathResult *gavin_xpath(const char *html, const char *expression, int markup, int document_context);
void gavin_xpath_free(GavinXPathResult *result);
#endif
