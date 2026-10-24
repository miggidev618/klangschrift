#include <sqlite3.h>

int klangschrift_sqlite_enable_defensive(sqlite3 *database);
int klangschrift_sqlite_handle_has_not_moved(sqlite3 *database);
int klangschrift_swap_paths(const char *left, const char *right);
