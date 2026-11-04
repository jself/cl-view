/* SQLITE_TRANSIENT is the pointer value -1, which Zig rejects as a function
 * pointer on targets that require aligned code addresses (aarch64). */
#include "sqlite3.h"

int cl_sqlite_bind_text(sqlite3_stmt *stmt, int i, const char *text, int len) {
    return sqlite3_bind_text(stmt, i, text, len, SQLITE_TRANSIENT);
}
