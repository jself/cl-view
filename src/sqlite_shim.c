/* SQLITE_TRANSIENT is the pointer value -1, which Zig rejects as a function
 * pointer on targets that require aligned code addresses (aarch64). */
#include "sqlite3.h"

int cl_sqlite_bind_text(sqlite3_stmt *stmt, int i, const char *text, int len) {
    return sqlite3_bind_text(stmt, i, text, len, SQLITE_TRANSIENT);
}

/* One page cache for every connection in the process (see db.configure). */
#include <stdlib.h>

int cl_sqlite_page_cache(int page_size, int lines) {
    int hdr = 0;
    if (sqlite3_config(SQLITE_CONFIG_PCACHE_HDRSZ, &hdr) != SQLITE_OK) return SQLITE_ERROR;
    int sz = (page_size + hdr + 7) & ~7;
    void *buf = malloc((size_t)sz * (size_t)lines);
    if (!buf) return SQLITE_NOMEM;
    int rc = sqlite3_config(SQLITE_CONFIG_PAGECACHE, buf, sz, lines);
    if (rc != SQLITE_OK) free(buf);
    return rc;
}
