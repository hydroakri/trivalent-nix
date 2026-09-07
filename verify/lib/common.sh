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
  xmllint) echo "libxml2" ;;
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

# --- repodata (repomd.xml / primary.xml) readers -------------------------
# xmllint + `sort -V`, no python. These operate on already-fetched,
# already-signature-checked, already-decompressed files -- transport,
# decompression and signature verification stay in the caller. The
# `local-name()` predicates sidestep the repo/common XML namespaces.
#
# NB: newest-package selection is `sort -V`, not rpm's EVR algorithm. That is
# exact for Trivalent's purely-numeric `N.N.N.N-N` scheme (epoch 0, no
# ~/^/alpha segments). If upstream ever ships an epoch or an alpha tag,
# `sort -V` could disagree with rpm -- but both callers then cross-check the
# chosen v-r against an independent source (10-verify against the requested
# VR; 20-version-map against GitHub) and fail closed on a mismatch, so a bad
# pick degrades to an alarm, never a silent wrong pin.

# repomd_primary_location <repomd.xml>  ->  "<href>\t<ck-type>\t<ck-hex>"
repomd_primary_location() {
  local f="$1" href ct cs base='//*[local-name()="data"][@type="primary"]'
  href="$(xmllint --xpath "string($base/*[local-name()=\"location\"]/@href)" "$f" 2>/dev/null)" || return 1
  ct="$(xmllint --xpath "string($base/*[local-name()=\"checksum\"]/@type)" "$f" 2>/dev/null)" || return 1
  cs="$(xmllint --xpath "string($base/*[local-name()=\"checksum\"])" "$f" 2>/dev/null)" || return 1
  [ -n "$href" ] && [ -n "$ct" ] && [ -n "$cs" ] || return 1
  printf '%s\t%s\t%s\n' "$href" "$ct" "$cs"
}

# repomd_newest_pkg <primary.xml> <name> <arch>
#   -> "<ver>-<rel>\t<href>\t<ck-type>\t<ck-hex>"  for the highest v-r
#   return 3 if no such package; return 1 on a malformed / misaligned document
repomd_newest_pkg() {
  local f="$1" name="$2" arch="$3"
  local pred='//*[local-name()="package"][*[local-name()="name"]="'"$name"'"][*[local-name()="arch"]="'"$arch"'"]'
  local vers rels hrefs cts css nv nr nh nc ns
  vers="$(xmllint --xpath "$pred/*[local-name()=\"version\"]/@ver" "$f" 2>/dev/null | grep -oE 'ver="[^"]*"' | sed -E 's/ver="([^"]*)"/\1/')"
  rels="$(xmllint --xpath "$pred/*[local-name()=\"version\"]/@rel" "$f" 2>/dev/null | grep -oE 'rel="[^"]*"' | sed -E 's/rel="([^"]*)"/\1/')"
  hrefs="$(xmllint --xpath "$pred/*[local-name()=\"location\"]/@href" "$f" 2>/dev/null | grep -oE 'href="[^"]*"' | sed -E 's/href="([^"]*)"/\1/')"
  cts="$(xmllint --xpath "$pred/*[local-name()=\"checksum\"]/@type" "$f" 2>/dev/null | grep -oE 'type="[^"]*"' | sed -E 's/type="([^"]*)"/\1/')"
  css="$(xmllint --xpath "$pred/*[local-name()=\"checksum\"]/text()" "$f" 2>/dev/null | grep -oE '[0-9a-fA-F]{8,}')"
  [ -n "$vers" ] || return 3
  nv=$(printf '%s\n' "$vers" | grep -c .)
  nr=$(printf '%s\n' "$rels" | grep -c .)
  nh=$(printf '%s\n' "$hrefs" | grep -c .)
  nc=$(printf '%s\n' "$cts" | grep -c .)
  ns=$(printf '%s\n' "$css" | grep -c .)
  { [ "$nv" = "$nr" ] && [ "$nv" = "$nh" ] && [ "$nv" = "$nc" ] && [ "$nv" = "$ns" ]; } || return 1
  paste <(printf '%s\n' "$vers") <(printf '%s\n' "$rels") <(printf '%s\n' "$hrefs") \
    <(printf '%s\n' "$cts") <(printf '%s\n' "$css") |
    awk -F'\t' 'NF>=5 {printf "%s-%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5}' |
    sort -V | tail -n1 | grep .
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
