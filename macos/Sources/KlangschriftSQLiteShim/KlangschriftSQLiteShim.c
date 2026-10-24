#include "KlangschriftSQLiteShim.h"
#include <stdio.h>
#include <fcntl.h>

int klangschrift_sqlite_enable_defensive(sqlite3 *database) {
    int ignored = 0;
    return sqlite3_db_config(database, SQLITE_DBCONFIG_DEFENSIVE, 1, &ignored);
}

int klangschrift_sqlite_handle_has_not_moved(sqlite3 *database) {
    int moved = 1;
    int rc = sqlite3_file_control(database, "main", SQLITE_FCNTL_HAS_MOVED, &moved);
    return (rc == SQLITE_OK && moved == 0) ? SQLITE_OK : (rc == SQLITE_OK ? SQLITE_NOTADB : rc);
}

int klangschrift_swap_paths(const char *left, const char *right) {
#if defined(__APPLE__)
    return renameatx_np(AT_FDCWD, left, AT_FDCWD, right, RENAME_SWAP);
#else
    (void)left; (void)right;
    return -1;
#endif
}
