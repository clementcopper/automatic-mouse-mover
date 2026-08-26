#ifndef AMM_MENUBAR_H
#define AMM_MENUBAR_H

// Sets up the status item and runs the AppKit event loop. Blocks until quit.
void amm_menubar_run(void);

void amm_menubar_set_icon(const void *data, int len);
int amm_menubar_add_item(const char *title, const char *tooltip);
void amm_menubar_add_separator(void);
void amm_menubar_set_enabled(int itemID, int enabled);
void amm_menubar_quit(void);

#endif
