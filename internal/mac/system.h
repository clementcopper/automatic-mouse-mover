#ifndef AMM_SYSTEM_H
#define AMM_SYSTEM_H

// SMAppServiceStatus values: 0 not registered, 1 enabled, 2 requires approval, 3 not found.
// -1 means the call itself failed.
int amm_login_item_status(void);
// Returns 0 on success, or a negative code with the reason written to errBuf.
int amm_login_item_set(int enabled, char *errBuf, int errBufLen);

int amm_pref_bool(const char *key, int fallback);
void amm_pref_set_bool(const char *key, int value);

void amm_watch_wake(void);

#endif
