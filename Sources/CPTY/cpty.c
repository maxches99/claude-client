#define _XOPEN_SOURCE 600
#define _DEFAULT_SOURCE
#define _DARWIN_C_SOURCE
#include "cpty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

int ccr_pty_spawn(const char *path, char *const argv[], char *const envp[], const char *cwd,
                  unsigned short cols, unsigned short rows, int *master_out, pid_t *pid_out) {
    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) return errno;
    if (grantpt(master) != 0 || unlockpt(master) != 0) {
        int e = errno;
        close(master);
        return e;
    }
    const char *name = ptsname(master);
    if (name == NULL) {
        int e = errno;
        close(master);
        return e ? e : ENOENT;
    }
    char slave_name[256];
    strncpy(slave_name, name, sizeof(slave_name) - 1);
    slave_name[sizeof(slave_name) - 1] = '\0';

    // Nothing else the daemon starts should inherit the master side.
    fcntl(master, F_SETFD, FD_CLOEXEC);

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;
    ioctl(master, TIOCSWINSZ, &ws);

    pid_t pid = fork();
    if (pid < 0) {
        int e = errno;
        close(master);
        return e;
    }
    if (pid == 0) {
        // Child: only async-signal-safe calls from here to exec.
        setsid();
        int slave = open(slave_name, O_RDWR);
        if (slave < 0) _exit(127);
        ioctl(slave, TIOCSCTTY, 0);
        ioctl(slave, TIOCSWINSZ, &ws);
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) close(slave);

        // The daemon ignores SIGPIPE and may block signals on its threads; a shell must start clean.
        struct sigaction dfl;
        memset(&dfl, 0, sizeof(dfl));
        dfl.sa_handler = SIG_DFL;
        for (int sig = 1; sig < 32; sig++) {
            if (sig == SIGKILL || sig == SIGSTOP) continue;
            sigaction(sig, &dfl, NULL);
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);

        if (cwd != NULL && cwd[0] != '\0') chdir(cwd);
        execve(path, argv, envp);
        _exit(127);
    }
    *master_out = master;
    *pid_out = pid;
    return 0;
}

int ccr_pty_resize(int master, unsigned short cols, unsigned short rows) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = cols;
    ws.ws_row = rows;
    return ioctl(master, TIOCSWINSZ, &ws) == 0 ? 0 : errno;
}
