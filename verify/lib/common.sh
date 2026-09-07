# Shared prelude for the verify/ scripts. Sourced, not executed.
#
# Responsibilities:
#   - locate repo root and source fingerprint.env
#   - re-exec the caller inside `nix shell` if required CLIs are missing, so the
#     scripts are runnable on a bare NixOS box without a devShell
#   - small logging helpers
#
# Every caller must set  NEED_TOOLS="a b c"  BEFORE sourcing this file.

set -euo pipefail

_self="${BASH_SOURCE[1]:-$0}"
REPO_ROOT="$(cd "$(dirname "$_self")/.." && pwd)"
VERIFY_DIR="$REPO_ROOT/verify"

# shellcheck source=/dev/null
. "$VERIFY_DIR/fingerprint.env"

# --- tool bootstrap ---------------------------------------------------------
# Map a CLI name -> nixpkgs attribute (only where they differ from the binary).
_nixattr() {
  case "$1" in
  gpg | gpgv) echo "gnupg" ;;
  rpm2cpio | rpmkeys) echo "rpm" ;;
  sha256sum | b2sum | mktemp) echo "coreutils" ;;
  *) echo "$1" ;;
  esac
}

_missing_tools() {
  local t missing=""
  for t in $NEED_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  echo "${missing# }"
}

if [ -z "${TRIVALENT_VERIFY_INSHELL:-}" ]; then
  _miss="$(_missing_tools)"
  if [ -n "$_miss" ]; then
    _attrs=""
    for t in $_miss; do _attrs="$_attrs nixpkgs#$(_nixattr "$t")"; done
    # dedupe
    _attrs="$(printf '%s\n' $_attrs | sort -u | tr '\n' ' ')"
    echo "[common] missing:$_miss -> re-exec inside: nix shell$_attrs" >&2
    export TRIVALENT_VERIFY_INSHELL=1
    # shellcheck disable=SC2086
    exec nix --extra-experimental-features "nix-command flakes" shell $_attrs \
      nixpkgs#cacert -c "$_self" "$@"
  fi
fi
export TRIVALENT_VERIFY_INSHELL=1
export SSL_CERT_FILE="${SSL_CERT_FILE:-${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}}"

# --- logging --------------------------------------------------------------
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit "${2:-1}"
}
have() { command -v "$1" >/dev/null 2>&1; }

# Decompress <src> to <dst> (distinct paths), format sniffed by magic bytes.
decompress_to() {
  local src="$1" dst="$2" magic
  magic="$(od -An -tx1 -N6 "$src" | tr -d ' \n')"
  case "$magic" in
  1f8b*) gzip -dc "$src" >"$dst" ;;
  28b52ffd*) zstd -dc "$src" >"$dst" ;;
  fd377a585a*) xz -dc "$src" >"$dst" ;;
  425a68*) bzip2 -dc "$src" >"$dst" ;;
  *) cp "$src" "$dst" ;;
  esac
}

# Fetch with retries; https-only, except an explicit loopback URL (fixture tests).
fetch() {
  local u="" a
  for a in "$@"; do case "$a" in http://* | https://*)
    u="$a"
    break
    ;;
  esac done
  case "$u" in
  http://127.0.0.1[:/]* | http://localhost[:/]*)
    curl -fsSL --retry 5 --retry-connrefused "$@"
    ;;
  *)
    curl -fsSL --retry 5 --retry-connrefused --proto '=https' --tlsv1.2 "$@"
    ;;
  esac
}
