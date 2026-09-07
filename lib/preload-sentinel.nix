# A tiny .so whose ELF constructor records "who loaded me" -- the shared canary
# for the behavioural preload checks (verify/30 layer, and any future VM test).
#
#   SENTINEL_LOG=<file> LD_PRELOAD=${preload-sentinel}/lib/libsentinel.so <cmd>
#
# Every process that honours LD_PRELOAD / LD_AUDIT / LD_PROFILE and links it
# appends one line:  SENTINEL pid=<pid> ppid=<ppid> exe=<realpath of /proc/self/exe>
# If Chromium (exe .../trivalent, chrome_crashpad_handler, a --type=zygote) ever
# shows up, a system-wide preload reached the browser -- the regression we guard.
{ runCommandCC }:

runCommandCC "preload-sentinel" { } ''
  mkdir -p "$out/lib"
  cat > sentinel.c <<'EOF'
  #define _GNU_SOURCE
  #include <stdio.h>
  #include <stdlib.h>
  #include <unistd.h>

  __attribute__((constructor))
  static void sentinel_ctor(void) {
    const char *p = getenv("SENTINEL_LOG");
    FILE *f = fopen((p && *p) ? p : "/tmp/preload-sentinel.log", "a");
    if (!f) return;
    char exe[4096];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
    exe[(n > 0) ? n : 0] = '\0';
    fprintf(f, "SENTINEL pid=%ld ppid=%ld exe=%s\n",
            (long) getpid(), (long) getppid(), exe);
    fclose(f);
  }
  EOF
  $CC -shared -fPIC -O2 -Wall -Wextra -o "$out/lib/libsentinel.so" sentinel.c
''
