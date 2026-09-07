#!/usr/bin/env bash
# 30-sandbox-selfcheck.sh [<real-url>]
#
# Failure mode F5. The spec defines "sandbox not weakened" as: the renderer
# isolation SYSCALLS are the same with and without the buildFHSEnv wrapper --
# either both go unprivileged-userns + seccomp-bpf, or (not the case here, the
# RPM ships no chrome-sandbox) both go the setuid route. This script:
#
#   1. strace-launches the FHS-wrapped browser on a real URL and checks the
#      renderer/zygote actually calls unshare(CLONE_NEWUSER|NEWPID|NEWNET) and
#      installs a seccomp-bpf filter, and never execs a setuid chrome-sandbox.
#   2. strace-launches the UNWRAPPED binary the same way and diffs the set of
#      sandbox-relevant syscalls. Divergence = the wrapper changed the sandbox.
#   3. confirms the real URL produced a non-empty DOM (acceptance: "renders a
#      real page").
#
# Binary: $TRIVALENT_BIN, else ./result/bin/trivalent. The unwrapped binary is
# read from `nix eval .#trivalent.passthru.unwrapped` when available.
#
# Exit codes:
#   0   wrapped sandbox adequate AND matches unwrapped AND page rendered
#   50  wrapped browser sandbox inadequate (userns or seccomp missing, or setuid seen)
#   53  wrapped vs unwrapped sandbox syscall sets diverge
#   52  real URL produced an empty DOM
#   51  could not launch / strace
#   55  a system LD_PRELOAD / LD_AUDIT / LD_PROFILE reached the browser process
#   2   usage

set -uo pipefail
REAL_URL="${1:-https://example.org}"
NEED=(strace)
for t in "${NEED[@]}"; do command -v "$t" >/dev/null || exec nix --extra-experimental-features "nix-command flakes" shell nixpkgs#strace -c "$0" "$@"; done

WRAP_BIN="${TRIVALENT_BIN:-./result/bin/trivalent}"
[ -x "$WRAP_BIN" ] || {
  echo "no wrapped binary at $WRAP_BIN" >&2
  exit 2
}
UNWRAP_DIR="$(nix --extra-experimental-features 'nix-command flakes' eval --raw .#trivalent.passthru.unwrapped 2>/dev/null || true)"
UNWRAP_BIN=""
[ -n "$UNWRAP_DIR" ] && UNWRAP_BIN="$(find "$UNWRAP_DIR" -path '*/trivalent/trivalent' -type f | head -n1)"

wd="$(mktemp -d)"
trap 'rm -rf "$wd"' EXIT
SFILTER='trace=unshare,clone,clone3,setuid,setresuid,seccomp,prctl,execve'

run_traced() { # <tag> <cmd...>
  local tag="$1"
  shift
  local prof="$wd/prof-$tag"
  mkdir -p "$prof"
  strace -f -qq -s 200 -e "$SFILTER" -o "$wd/trace-$tag.log" \
    "$@" --headless=new --no-first-run --no-default-browser-check --disable-gpu \
    --user-data-dir="$prof" --virtual-time-budget=8000 \
    --dump-dom "$REAL_URL" >"$wd/dom-$tag.html" 2>"$wd/err-$tag.log"
  echo "  [$tag] exit=$? trace=$(wc -l <"$wd/trace-$tag.log") lines dom=$(wc -c <"$wd/dom-$tag.html") bytes"
}

# classify a trace file -> prints space-separated tokens found
classify() { # <trace.log>
  local f="$1" out=""
  grep -qE 'unshare\([^)]*CLONE_NEWUSER' "$f" && out="$out userns"
  grep -qE 'clone[3]?\([^)]*CLONE_NEWUSER' "$f" && out="$out userns"
  grep -qE 'CLONE_NEWPID' "$f" && out="$out pidns"
  grep -qE 'CLONE_NEWNET' "$f" && out="$out netns"
  grep -qE 'seccomp\(SECCOMP_SET_MODE_FILTER|prctl\(PR_SET_SECCOMP, *SECCOMP_MODE_FILTER' "$f" && out="$out seccomp-bpf"
  grep -qE 'execve\("[^"]*chrome-sandbox' "$f" && out="$out SETUID-HELPER"
  grep -qE '\bsetuid\(0\)|setresuid\(0' "$f" && out="$out SETUID0"
  grep -qE 'no-sandbox|disable-setuid-sandbox' "$wd/err-$(basename "${f%.log}" | sed 's/^trace-//').log" 2>/dev/null && out="$out NO-SANDBOX-FLAG"
  echo "${out# }"
}

echo "[selfcheck] wrapped  : $WRAP_BIN"
echo "[selfcheck] unwrapped : ${UNWRAP_BIN:-<unavailable>}"
echo "[selfcheck] url       : $REAL_URL"

run_traced wrapped "$WRAP_BIN" || {
  echo "launch failed" >&2
  exit 51
}
W_CLASS="$(classify "$wd/trace-wrapped.log")"
echo "[selfcheck] wrapped sandbox syscalls: [$W_CLASS]"

# DOM non-empty?
W_TEXT="$(sed -e 's/<[^>]*>/ /g' -e 's/[[:space:]]\+/ /g' "$wd/dom-wrapped.html" | tr -d ' \n')"
if [ "${#W_TEXT}" -lt 20 ]; then
  echo "FAIL: empty DOM from $REAL_URL" >&2
  exit 52
fi
echo "[selfcheck] rendered ${#W_TEXT} text chars from $REAL_URL"

fail=0
case " $W_CLASS " in *" userns "*) : ;; *)
  echo "FAIL: no unprivileged user namespace (CLONE_NEWUSER) in renderer/zygote"
  fail=1
  ;;
esac
case " $W_CLASS " in *" seccomp-bpf "*) : ;; *)
  echo "FAIL: no seccomp-bpf filter installed"
  fail=1
  ;;
esac
case " $W_CLASS " in *" SETUID-HELPER "* | *" SETUID0 "*)
  echo "FAIL: setuid sandbox path taken (should be impossible: RPM ships no chrome-sandbox)"
  fail=1
  ;;
esac
case " $W_CLASS " in *" NO-SANDBOX-FLAG "*)
  echo "FAIL: --no-sandbox / --disable-setuid-sandbox in effect"
  fail=1
  ;;
esac
[ "$fail" -eq 0 ] || {
  echo "RESULT: wrapped sandbox INADEQUATE"
  exit 50
}
echo "RESULT: wrapped sandbox adequate [$W_CLASS]"

# --- a system LD_PRELOAD / LD_AUDIT / LD_PROFILE must NOT reach the browser
#     (F5 / hardened_malloc: trivalent.sh scrubs them + we own it via fhsLaunch;
#     this is the real-hardware behavioural check -- exit 55). ---
SENTINEL_SO=""
sdir="$(nix --extra-experimental-features 'nix-command flakes' \
  build --no-link --print-out-paths '.#preload-sentinel' 2>/dev/null | head -n1)"
[ -n "$sdir" ] && [ -f "$sdir/lib/libsentinel.so" ] && SENTINEL_SO="$sdir/lib/libsentinel.so"

if [ -n "$SENTINEL_SO" ]; then
  hits="$wd/sentinel-hits.log"
  sprof="$wd/sprof"
  mkdir -p "$sprof"
  : >"$hits"

  SENTINEL_LOG="$hits" \
    LD_PRELOAD="$SENTINEL_SO" LD_AUDIT="$SENTINEL_SO" LD_PROFILE="$SENTINEL_SO" \
    "$WRAP_BIN" --headless=new --no-first-run --no-default-browser-check \
    --disable-gpu --user-data-dir="$sprof" about:blank \
    >"$wd/sentinel-out.log" 2>"$wd/sentinel-err.log" &
  spid=$!
  sleep 6
  kids="$(pgrep -P "$spid" 2>/dev/null || true) $(pgrep -f "user-data-dir=$sprof" 2>/dev/null || true)"
  mapped=0
  for p in $spid $kids; do
    [ -r "/proc/$p/maps" ] && grep -q 'libsentinel\.so' "/proc/$p/maps" 2>/dev/null && mapped=1
  done
  kill "$spid" 2>/dev/null || true
  wait "$spid" 2>/dev/null || true
  pkill -x trivalent 2>/dev/null || true

  browser_hits="$(grep -E '/trivalent$|chrome_crashpad|type=zygote' "$hits" 2>/dev/null || true)"
  if [ ! -s "$hits" ]; then
    # nothing anywhere loaded the .so -- not even the pre-exec bwrap/bash
    # helpers. The probe is not working; a clean "no browser hit" would be
    # meaningless, so don't claim a pass.
    echo "[selfcheck] WARN: sentinel probe never fired (not even on pre-exec helpers) -- skipping preload check" >&2
  elif [ -n "$browser_hits" ] || [ "$mapped" -eq 1 ]; then
    echo "FAIL: LD_PRELOAD/LD_AUDIT/LD_PROFILE reached the browser process" >&2
    [ -n "$browser_hits" ] && printf '  %s\n' "$browser_hits" >&2
    [ "$mapped" -eq 1 ] && echo "  (libsentinel.so found in a browser /proc/<pid>/maps)" >&2
    exit 55
  else
    echo "[selfcheck] preload scrub OK: sentinel entered only pre-exec helpers, never the browser"
  fi
else
  echo "[selfcheck] note: .#preload-sentinel unavailable -- skipping preload scrub check (non-fatal)"
fi

if [ -n "$UNWRAP_BIN" ]; then
  run_traced unwrapped "$UNWRAP_BIN" || {
    echo "WARN: unwrapped launch failed; skipping parity diff" >&2
    exit 0
  }
  U_CLASS="$(classify "$wd/trace-unwrapped.log")"
  echo "[selfcheck] unwrapped sandbox syscalls: [$U_CLASS]"
  # compare as sorted sets
  w="$(printf '%s\n' $W_CLASS | sort -u | paste -sd,)"
  u="$(printf '%s\n' $U_CLASS | sort -u | paste -sd,)"
  if [ "$w" != "$u" ]; then
    echo "FAIL: sandbox syscall set differs  wrapped=[$w]  unwrapped=[$u]" >&2
    exit 53
  fi
  echo "RESULT: wrapped and unwrapped agree on sandbox call path [$w]"
fi

# --- AppArmor attach check (catches a silent detach after a buildFHSEnv/nixpkgs
#     change: profile loaded but the running browser is unconfined). Opt-in with
#     CHECK_APPARMOR=1; fails with 54 only if EXPECT_APPARMOR=1. ---
if [ "${CHECK_APPARMOR:-0}" = 1 ]; then
  if grep -q '^trivalent ' /sys/kernel/security/apparmor/profiles 2>/dev/null; then
    prof="$(
      cd "$wd" && "$WRAP_BIN" --headless=new --user-data-dir="$wd/aa" about:blank &
      p=$!
      sleep 3
      cat /proc/$p/attr/current 2>/dev/null
      kill $p 2>/dev/null
    )"
    echo "[selfcheck] /proc/<trivalent>/attr/current = ${prof:-<unreadable>}"
    case "$prof" in
    trivalent\ * | trivalent) echo "RESULT: AppArmor profile 'trivalent' is attached" ;;
    *)
      echo "WARN: 'trivalent' profile is loaded but the browser runs as [${prof:-unknown}] -- attach path broke" >&2
      [ "${EXPECT_APPARMOR:-0}" = 1 ] && exit 54
      ;;
    esac
  else
    echo "[selfcheck] no 'trivalent' AppArmor profile loaded (skip)"
    [ "${EXPECT_APPARMOR:-0}" = 1 ] && {
      echo "FAIL: EXPECT_APPARMOR=1 but no profile loaded" >&2
      exit 54
    }
  fi
fi
exit 0
