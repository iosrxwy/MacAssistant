/*
 * 能耗模式的常驻 root 辅助进程。
 * 父进程只在第一次切换时通过 osascript 把它提权拉起来，之后切模式只往套接字写一行。
 * 这里不跑 shell：只接受六种固定指令，并原样交给 /usr/bin/pmset。
 */

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int write_all(int fd, const char *text) {
    size_t length = strlen(text);
    size_t sent = 0;
    while (sent < length) {
        ssize_t count = write(fd, text + sent, length - sent);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (count == 0) {
            return -1;
        }
        sent += (size_t)count;
    }
    return 0;
}

/* 1 读到一行，0 对端关闭，-1 出错或一行长得不像协议。 */
static int read_line(int fd, char *buffer, size_t capacity) {
    size_t used = 0;
    if (capacity == 0) {
        return -1;
    }
    while (used + 1 < capacity) {
        char byte = 0;
        ssize_t count = read(fd, &byte, 1);
        if (count == 0) {
            return 0;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }
        if (byte == '\n') {
            buffer[used] = '\0';
            return 1;
        }
        if (byte != '\r') {
            buffer[used++] = byte;
        }
    }
    return -1;
}

static int run_pmset(const char *flag, const char *mode) {
    char arg0[] = "/usr/bin/pmset";
    char arg2[] = "powermode";
    char flag_buf[4];
    char mode_buf[4];
    char *argv[5];
    posix_spawn_file_actions_t actions;
    pid_t pid = 0;
    int status = 0;
    int devnull = -1;
    int rc;

    if (snprintf(flag_buf, sizeof(flag_buf), "%s", flag) < 0) {
        return 0;
    }
    if (snprintf(mode_buf, sizeof(mode_buf), "%s", mode) < 0) {
        return 0;
    }
    argv[0] = arg0;
    argv[1] = flag_buf;
    argv[2] = arg2;
    argv[3] = mode_buf;
    argv[4] = NULL;

    if (posix_spawn_file_actions_init(&actions) != 0) {
        return 0;
    }
    devnull = open("/dev/null", O_RDWR);
    if (devnull < 0) {
        posix_spawn_file_actions_destroy(&actions);
        return 0;
    }
    if (posix_spawn_file_actions_adddup2(&actions, devnull, STDIN_FILENO) != 0
        || posix_spawn_file_actions_adddup2(&actions, devnull, STDOUT_FILENO) != 0
        || posix_spawn_file_actions_adddup2(&actions, devnull, STDERR_FILENO) != 0
        || posix_spawn_file_actions_addclose(&actions, devnull) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        close(devnull);
        return 0;
    }
    rc = posix_spawn(&pid, arg0, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(devnull);
    if (rc != 0) {
        return 0;
    }
    if (waitpid(pid, &status, 0) < 0) {
        return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

/* 1 已切换，0 pmset 失败，-1 不是允许的指令。 */
static int apply_line(const char *line) {
    if (strcmp(line, "-b 0") == 0) return run_pmset("-b", "0");
    if (strcmp(line, "-b 1") == 0) return run_pmset("-b", "1");
    if (strcmp(line, "-b 2") == 0) return run_pmset("-b", "2");
    if (strcmp(line, "-c 0") == 0) return run_pmset("-c", "0");
    if (strcmp(line, "-c 1") == 0) return run_pmset("-c", "1");
    if (strcmp(line, "-c 2") == 0) return run_pmset("-c", "2");
    return -1;
}

static int connect_socket(const char *path) {
    struct sockaddr_un addr;
    size_t length;
    int fd;
    int nosigpipe = 1;

    if (path == NULL || path[0] != '/') {
        return -1;
    }
    length = strlen(path);
    if (length == 0 || length >= sizeof(addr.sun_path) || strchr(path, '\n') != NULL) {
        return -1;
    }
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        close(fd);
        return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, sizeof(nosigpipe));
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    addr.sun_len = (unsigned char)sizeof(addr);
    memcpy(addr.sun_path, path, length);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int main(int argc, char **argv) {
    int fd;
    char line[32];

    signal(SIGPIPE, SIG_IGN);
    if (argc != 2) {
        return 2;
    }
    fd = connect_socket(argv[1]);
    if (fd < 0) {
        return 1;
    }
    for (;;) {
        int got = read_line(fd, line, sizeof(line));
        int applied;
        if (got <= 0) {
            break;
        }
        if (strcmp(line, "quit") == 0) {
            break;
        }
        applied = apply_line(line);
        if (write_all(fd, applied == 1 ? "ok\n" : "no\n") != 0) {
            break;
        }
    }
    close(fd);
    return 0;
}
