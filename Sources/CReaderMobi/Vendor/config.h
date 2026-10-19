/** @file src/config.h
 *
 * Copyright (c) 2014 Bartek Fabiszewski
 * http://www.fabiszewski.net
 *
 * This file is part of libmobi.
 * Licensed under LGPL, either version 3, or any later.
 * See <http://www.gnu.org/licenses/>
 */

#ifndef mobi_config_h
#define mobi_config_h

#ifdef HAVE_CONFIG_H
#include "../config.h"
#endif

#endif

/* Gavin Apple-platform build; DRM disabled. */
#define USE_XMLWRITER 1
#define USE_LIBXML2 1
#define HAVE_STRDUP 1
#define PACKAGE_VERSION "0.12"
