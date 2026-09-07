#!/usr/bin/env bash
# 20-version-map.sh <arch>   (arch: x86_64 | aarch64)
#
# Failure mode F3: GitHub Releases and repo.secureblue.dev can disagree. Two
# reasons -- benign distribution lag, or distribution-side tampering -- and they
# must not be conflated. This script derives the "current trivalent version"
# from BOTH sides INDEPENDENTLY and classifies the disagreement.
#
#   Path A (repo)   : repomd.xml -> primary.xml -> newest trivalent-<v-r>.<arch>
#   Path B (github) : gh release list, newest-first; for each, read its
#                     multiple.intoto.jsonl and keep the first whose SLSA
#                     subjects contain trivalent-<tag>.<arch>.rpm.
#                     (secureblue publishes x86_64 and aarch64 as SEPARATE,
#                     alternating release tags -- Path B must be arch-scoped or
#                     it will read the other arch's newer tag as a false lag.)
#   Existence check : the release named <A> must exist AND its provenance must
#                     carry trivalent-<A>.<arch>.rpm. Path B never trusts Path
#                     A's string beyond looking it up.
#
# Exit codes (each is a machine decision, no "looks ok"):
#   0   A == B and tag A exists       -> prints  VERSION=<v-r>   on stdout
#   10  A older than B (repomd lag)   -> benign; retried up to VMAP_RETRIES
#   21  still lagging after budget    -> ALARM (not a silent skip)
#   20  repomd names a v-r with no GitHub release, OR repomd ahead of published
#                                     -> ALARM: possible distribution tampering
#   22  a side is missing/unparseable -> ALARM: refuse to guess
#
# Env: VMAP_RETRIES (default 12), VMAP_INTERVAL seconds (default 300).
# This script does NO signature checking and writes NO nix hash. Its only
# hand-off is the VERSION= line; the caller must then run 10-verify-supply-chain.sh
# and gate everything downstream on ITS exit status.

NEED_TOOLS="curl gh jq xmllint gzip zstd"
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

arch="${1:-}"
case "$arch" in
x86_64 | aarch64) ;;
*) die "usage: $0 <x86_64|aarch64>" 2 ;;
esac

VMAP_RETRIES="${VMAP_RETRIES:-12}"
VMAP_INTERVAL="${VMAP_INTERVAL:-300}"
VR_RE='^[0-9]+(\.[0-9]+){3}-[0-9]+$'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

path_a() { # -> echoes v-r  ; exit 22 on parse failure
  fetch "$SECUREBLUE_REPO_BASEURL/repodata/repomd.xml" -o "$work/repomd.xml" ||
    die "Path A: cannot fetch repomd.xml" 22
  local pl href
  pl="$(repomd_primary_location "$work/repomd.xml")" ||
    die "Path A: cannot read primary location" 22
  href="$(printf '%s' "$pl" | cut -f1)"
  fetch "$SECUREBLUE_REPO_BASEURL/$href" -o "$work/primary.bin" ||
    die "Path A: cannot fetch $href" 22
  decompress_to "$work/primary.bin" "$work/primary.xml" ||
    die "Path A: cannot decompress primary" 22
  local row
  if ! row="$(repomd_newest_pkg "$work/primary.xml" trivalent "$arch")"; then
    die "Path A: no trivalent/$arch package in repodata" 22
  fi
  printf '%s' "$row" | cut -f1
}

# subjects of a release's SLSA provenance, one per line ("" if no such asset)
prov_subjects() { # <tag>
  local f="$work/prov-$1.jsonl"
  [ -f "$f" ] || gh release download "$1" --repo "$TRIVALENT_GH_REPO" \
    --pattern 'multiple.intoto.jsonl' --dir "$work" --clobber 2>/dev/null &&
    mv -f "$work/multiple.intoto.jsonl" "$f" 2>/dev/null || true
  [ -s "$f" ] || return 0
  jq -r '.dsseEnvelope.payload | @base64d | fromjson | .subject[].name' "$f" 2>/dev/null || true
}

# does <tag>'s provenance attest the trivalent RPM for THIS arch?
prov_has_arch() { # <tag>
  prov_subjects "$1" | grep -qx "trivalent-$1.$arch.rpm"
}

path_b() { # -> echoes newest GH release tag whose provenance is for $arch ; exit 22
  local tags t
  tags="$(gh release list --repo "$TRIVALENT_GH_REPO" --limit 100 \
    --json tagName --jq '.[].tagName' 2>/dev/null)" ||
    die "Path B: gh release list failed" 22
  for t in $(printf '%s\n' "$tags" | grep -E "$VR_RE" | sort -Vr); do
    if prov_has_arch "$t"; then
      printf '%s' "$t"
      return 0
    fi
  done
  die "Path B: no release provenance carries trivalent-*.$arch.rpm" 22
}

tag_exists() { # <tag> : release exists AND its provenance is for $arch
  gh release view "$1" --repo "$TRIVALENT_GH_REPO" --json tagName >/dev/null 2>&1 &&
    prov_has_arch "$1"
}

older() { # older <x> <y> : true if x strictly older than y
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

attempt=0
while :; do
  A="$(path_a)"
  rc=$?
  [ $rc -eq 0 ] || exit $rc
  B="$(path_b)"
  rc=$?
  [ $rc -eq 0 ] || exit $rc
  log "Path A (repomd)      : $A"
  log "Path B (github newest): $B"

  if ! gh release view "$A" --repo "$TRIVALENT_GH_REPO" --json tagName >/dev/null 2>&1; then
    printf 'ALARM: repodata advertises trivalent %s but GitHub has no release tagged %s.\n' "$A" "$A" >&2
    printf '       Benign lag makes GitHub *ahead*, never behind -- treat as distribution tampering.\n' >&2
    exit 20
  fi
  if ! prov_has_arch "$A"; then
    printf 'ALARM: GitHub release %s exists but its SLSA provenance does not attest trivalent-%s.%s.rpm.\n' "$A" "$A" "$arch" >&2
    printf '       repodata and the published provenance disagree about what was built for %s.\n' "$arch" >&2
    exit 20
  fi

  if [ "$A" = "$B" ]; then
    log "match."
    echo "VERSION=$A"
    exit 0
  fi

  if older "$A" "$B"; then
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$VMAP_RETRIES" ]; then
      printf 'ALARM: repodata still at %s while GitHub is at %s after %d checks (%ds apart).\n' \
        "$A" "$B" "$VMAP_RETRIES" "$VMAP_INTERVAL" >&2
      exit 21
    fi
    log "repomd lagging GitHub (attempt $attempt/$VMAP_RETRIES); sleeping ${VMAP_INTERVAL}s"
    sleep "$VMAP_INTERVAL"
    continue
  fi

  # A newer than B, yet tag A exists -> A is an unlisted/draft/prerelease ahead
  # of the newest *listed* release. repodata should never lead published state.
  printf 'ALARM: repodata (%s) is ahead of the newest listed GitHub release (%s).\n' "$A" "$B" >&2
  exit 20
done
