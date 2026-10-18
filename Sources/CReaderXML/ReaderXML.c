#include "ReaderXML.h"
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

GavinXPathResult *gavin_xpath(const char *html, const char *expression, int markup, int document_context) {
    GavinXPathResult *result = calloc(1, sizeof(GavinXPathResult));
    if (!result) return NULL;
    if (!html || !expression || strlen(html) > INT_MAX) { result->error = strdup("Invalid XPath input"); return result; }
    htmlDocPtr doc = htmlReadMemory(html, (int)strlen(html), NULL, "UTF-8", HTML_PARSE_RECOVER | HTML_PARSE_NONET | HTML_PARSE_NOERROR | HTML_PARSE_NOWARNING);
    if (!doc) { result->error = strdup("Could not parse HTML for XPath"); return result; }
    xmlXPathContextPtr context = xmlXPathNewContext(doc);
    if (!context) { xmlFreeDoc(doc); result->error = strdup("Could not allocate XPath context"); return result; }
    context->node = xmlDocGetRootElement(doc);
    if (!document_context) {
        xmlNodePtr body = context->node ? context->node->children : NULL;
        for (; body; body = body->next) { if (body->type == XML_ELEMENT_NODE && xmlStrEqual(body->name, BAD_CAST "body")) break; }
        if (body) {
            xmlNodePtr child = body->children;
            for (; child && child->type != XML_ELEMENT_NODE; child = child->next) {}
            if (child) context->node = child;
        }
    }
    xmlXPathObjectPtr object = xmlXPathEvalExpression(BAD_CAST expression, context);
    if (!object) { result->error = strdup("Invalid or unsupported XPath expression"); }
    else if (object->type == XPATH_NODESET) {
        int count = object->nodesetval ? object->nodesetval->nodeNr : 0;
        if (count > 20000) { result->error = strdup("XPath matched more than 20000 nodes"); }
        else if (count > 0) {
            result->values = calloc((size_t)count, sizeof(char *));
            if (!result->values) { result->error = strdup("Could not allocate XPath results"); }
            else for (int i = 0; i < count; i++) {
                xmlNodePtr node = object->nodesetval->nodeTab[i];
                if (markup) {
                    if (node->type != XML_ELEMENT_NODE) continue;
                    xmlBufferPtr buffer = xmlBufferCreate();
                    if (!buffer) continue;
                    xmlNodeDump(buffer, doc, node, 0, 0);
                    result->values[result->count++] = strdup((const char *)xmlBufferContent(buffer));
                    xmlBufferFree(buffer);
                } else {
                    xmlChar *text = xmlNodeGetContent(node);
                    if (text) { result->values[result->count++] = strdup((const char *)text); xmlFree(text); }
                }
            }
        }
    } else if (!markup) {
        xmlChar *text = xmlXPathCastToString(object);
        if (text) {
            result->values = calloc(1, sizeof(char *));
            if (result->values) { result->values[0] = strdup((const char *)text); result->count = 1; }
            xmlFree(text);
        }
    } else { result->error = strdup("XPath list must select HTML elements"); }
    if (object) xmlXPathFreeObject(object);
    xmlXPathFreeContext(context);
    xmlFreeDoc(doc);
    return result;
}

void gavin_xpath_free(GavinXPathResult *result) {
    if (!result) return;
    for (int i = 0; i < result->count; i++) free(result->values[i]);
    free(result->values); free(result->error); free(result);
}
