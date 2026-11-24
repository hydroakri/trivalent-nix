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
#   Tag naming      : upstream tags are <v-r>-<arch> since 2026-10 (bare <v-r>
#                     before); verify/lib/release-tag.sh resolves both.
#   Existence check : the release named <A> must exist AND its provenance must
#                     carry trivalent-<A>.<arch>.rpm. Path B never trusts Path
#                     A's string beyond looking it up.
#
# Exit codes (each is a machine decision, no "looks ok"):
#   0   A == B and tag A exists       -> prints  VERSION=<v-r>   on stdout
#   10  A older than B (repomd lag)   -> benign; retried up to VMAP_RETRIES
#   21  still lagging after budget    -> ALARM (not a silent skip)
#   23  repomd names a v-r that has NO GitHub release yet -> also prints
#       VERSION=<v-r> and REPOMD_REVISION=<unix-ts of the signed repomd.xml>.
#       Ambiguous on its own: could be a release still in flight (secureblue
#       pushes the RPM to the repo before cutting the GitHub release) OR
#       tampering. The CALLER decides -- run 10-verify: if the RPM passes
#       layers 1+2 and only layer 3 is "missing" (rc 31, not "changed" rc 30),
#       it's a genuine signed build with no provenance yet -> wait; escalate
#       only once REPOMD_REVISION is older than a grace window.
#   20  release A exists but its provenance is for the wrong arch, OR repomd is
#       ahead of an EXISTING newest release -> ALARM: distribution tampering
#   22  a side is missing/unparseable -> ALARM: refuse to guess
#
# Env: VMAP_RETRIES (default 12), VMAP_INTERVAL seconds (default 300).
# This script does NO signature checking and writes NO nix hash. Its only
# hand-off is the VERSION= line; the caller must then run 10-verify-supply-chain.sh
# and gate everything downstream on ITS exit status.

NEED_TOOLS="curl gh jq xmllint gzip zstd"
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"
# shellcheck source=lib/release-tag.sh
. "$VERIFY_DIR/lib/release-tag.sh"

arch="${1:-}"
case "$arch" in
x86_64 | aarch64) ;;
*) die "usage: $0 <x86_64|aarch64>" 2 ;;
esac

VMAP_RETRIES="${VMAP_RETRIES:-12}"
VMAP_INTERVAL="${VMAP_INTERVAL:-300}"

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

# subjects of a release's SLSA provenance, one per line ("" if no such asset).
# Reads either asset name (multiple.intoto.jsonl until 2026-10, provenance.intoto.json
# since) -- both are a DSSE envelope with the statement in .dsseEnvelope.payload.
# This only LISTS what a release claims, for the A-vs-B cross-check; whether the
# provenance is trustworthy is decided by layer 3 of 10-verify, not here.
prov_subjects() { # <tag>
  local d="$work/prov-$1" f
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    gh release download "$1" --repo "$TRIVALENT_GH_REPO" \
      --pattern 'multiple.intoto.jsonl' --pattern 'provenance.intoto.json' \
      --dir "$d" --clobber >/dev/null 2>&1 || true
  fi
  for f in "$d/multiple.intoto.jsonl" "$d/provenance.intoto.json"; do
    [ -s "$f" ] || continue
    jq -r '.dsseEnvelope.payload | @base64d | fromjson | .subject[].name' "$f" 2>/dev/null || true
  done
}

# does <tag>'s provenance attest the trivalent RPM for THIS arch?
prov_has_arch() { # <tag>
  local vr
  vr="$(release_tag_vr "$1" "$arch")" || return 1
  prov_subjects "$1" | grep -qx "trivalent-$vr.$arch.rpm"
}

path_b() { # -> echoes the v-r of the newest GH release whose provenance is for $arch ; exit 22
  local tags vr t
  tags="$(gh release list --repo "$TRIVALENT_GH_REPO" --limit 100 \
    --json tagName --jq '.[].tagName' 2>/dev/null)" ||
    die "Path B: gh release list failed" 22
  # "<v-r> <tag>" for every tag that is a v-r for THIS arch (old bare scheme or
  # new <v-r>-<arch>; the other arch's suffixed tags are skipped), newest first
  while read -r vr t; do
    if prov_has_arch "$t"; then
      printf '%s' "$vr"
      return 0
    fi
  done < <(
    for t in $tags; do
      vr="$(release_tag_vr "$t" "$arch")" && printf '%s %s\n' "$vr" "$t"
    done | sort -k1,1Vr
  )
  die "Path B: no release provenance carries trivalent-*.$arch.rpm" 22
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

  if ! T="$(release_resolve_tag "$A" "$arch" "$TRIVALENT_GH_REPO")"; then
    # repodata names a version with NO GitHub release. Hand it to the caller
    # with the signed repodata's own timestamp -- benign "release in flight"
    # vs tampering is decided against the RPM's signatures + a grace window.
    rev="$(xmllint --xpath 'string(//*[local-name()="revision"])' "$work/repomd.xml" 2>/dev/null)"
    printf 'PENDING: repodata advertises trivalent %s; GitHub has no release tagged %s or %s yet.\n' "$A" "$A-$arch" "$A" >&2
    echo "VERSION=$A"
    echo "REPOMD_REVISION=${rev:-0}"
    exit 23
  fi
  if ! prov_has_arch "$T"; then
    printf 'ALARM: GitHub release %s exists but its SLSA provenance does not attest trivalent-%s.%s.rpm.\n' "$T" "$A" "$arch" >&2
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
