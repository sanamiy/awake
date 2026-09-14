#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Signed entry point for launchd attribution. Keep restoration in the CLI.
// The installed pair remains usable even if the main app is moved or deleted.
int main(int argc, char *argv[]) {
    if (argc != 1) return 64;
    char executable[PATH_MAX], resolved[PATH_MAX], script[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 ||
        realpath(executable, resolved) == NULL) return 127;
    char *separator = strrchr(resolved, '/');
    if (separator == NULL) return 127;
    *separator = '\0';
    int length = snprintf(script, sizeof(script), "%s/lid-awake", resolved);
    if (length < 0 || (size_t)length >= sizeof(script)) return 127;
    execl("/bin/zsh", "zsh", "-f", "--", script, "_recover", (char *)NULL);
    perror("Awake recovery");
    return 127;
}
