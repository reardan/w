/* Optional on-device compiler probe. The host extracts the checkout's W
 * sources below root and packages libwcompiler.so built from compiler/cli.w.
 * Return 0 on success; the numbered stages are surfaced by the JNI host.
 * compiler_main is a process-entry API, so this function calls it at most once.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;
typedef int64_t (*compiler_main_fn)(int64_t, int64_t);
typedef int64_t (*program_fn)(void);

int wandroid_compiler_probe(const char *root) {
    static int called;
    if (called) return 1;
    called = 1;
    if (!root || root[0] != '/') return 2;
    int saved_cwd = open(".", O_PATH | O_CLOEXEC | O_DIRECTORY);
    if (saved_cwd < 0) return 3;
    int result = 4;
    void *compiler = NULL;
    void *program = NULL;
    char **args = NULL;
    char *output = NULL;
    int saved_stdout = -1;
    int saved_stderr = -1;
    int log_fd = -1;
    if (chdir(root) != 0) goto done;
    compiler = dlopen("libwcompiler.so", RTLD_NOW | RTLD_LOCAL);
    if (!compiler) { result = 5; goto done; }
    compiler_main_fn compile = (compiler_main_fn)dlsym(compiler, "compiler_main");
    if (!compile) { result = 6; goto done; }

    size_t env_count = 0;
    while (environ && environ[env_count]) ++env_count;
    /* compiler_main computes envp as argv + argc + 1. A conventional
     * isolated argv array would make that point outside the allocation. */
    const int argc = 7;
    args = calloc((size_t)argc + 1 + env_count + 1, sizeof(*args));
    output = malloc(strlen(root) + sizeof("/libprobe.so"));
    if (!args || !output) { result = 7; goto done; }
    sprintf(output, "%s/libprobe.so", root);
    args[0] = "w-android-device-compiler";
    args[1] = "arm64_android";
    args[2] = "--strict";
    args[3] = "--shared";
    args[4] = "tests/android_device_program.w";
    args[5] = "-o";
    args[6] = output;
    for (size_t i = 0; i < env_count; ++i) args[argc + 1 + i] = environ[i];
    /* A compile diagnostic may exit the process instead of returning.
     * Keep it in app-private storage even when cleanup cannot run. */
    log_fd = open("compiler.log", O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    saved_stdout = dup(STDOUT_FILENO);
    saved_stderr = dup(STDERR_FILENO);
    if (log_fd < 0 || saved_stdout < 0 || saved_stderr < 0) { result = 13; goto done; }
    if (dup2(log_fd, STDOUT_FILENO) < 0 || dup2(log_fd, STDERR_FILENO) < 0) { result = 14; goto done; }
    if (compile(argc, (int64_t)(intptr_t)args) != 0) { result = 8; goto done; }
    program = dlopen(output, RTLD_NOW | RTLD_LOCAL);
    if (!program) { result = 9; goto done; }
    program_fn probe = (program_fn)dlsym(program, "android_device_program");
    if (!probe) { result = 10; goto done; }
    result = probe() == 42 ? 0 : 11;

done:
    if (saved_stdout >= 0) { dup2(saved_stdout, STDOUT_FILENO); close(saved_stdout); }
    if (saved_stderr >= 0) { dup2(saved_stderr, STDERR_FILENO); close(saved_stderr); }
    if (log_fd >= 0) close(log_fd);
    if (program) dlclose(program);
    if (compiler) dlclose(compiler);
    free(args);
    free(output);
    if (fchdir(saved_cwd) != 0 && result == 0) result = 12;
    close(saved_cwd);
    return result;
}
