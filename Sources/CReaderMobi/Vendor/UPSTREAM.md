libmobi 0.12
Source: https://github.com/bfabiszewski/libmobi
Commit: 906274205c11944b628da1c553b255acb1af7c55
LGPL-3.0-or-later.
Selected library source files only; no DRM/encryption tools.
Changes: config.h adds Apple build macros; opf.c omits global xmlCleanupParser calls for concurrent reader safety.
All application and library sources plus the Xcode project are included in Gavin source distributions, enabling rebuilding and relinking with modified libmobi.
