#ifndef CPTY_H
#define CPTY_H

#include <sys/types.h>

/// Starts `path` with `argv` / `envp` in a new pseudo-terminal of `cols` × `rows`, as the session
/// leader with the terminal as its controlling tty (so ^C, job control and SIGWINCH behave), in
/// `cwd` when given. On success returns 0 and stores the master side and the child's pid; otherwise
/// returns an errno value. Written in C because only C can do the setup between fork and exec.
int ccr_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                  unsigned short cols, unsigned short rows, int *master_out, pid_t *pid_out);

/// Tells the terminal (and so the program in it) its new size.
int ccr_pty_resize(int master, unsigned short cols, unsigned short rows);

#endif
