# How an RPM version-release maps to an upstream GitHub release tag -- the ONE
# place that knows the tag naming. Sourced, not executed. Used by
# verify/20-version-map.sh and verify/10-verify-supply-chain.sh.
#
# Upstream (secureblue/Trivalent) has used two schemes:
#   <v-r>            e.g. 154.0.8037.97-447729          (until early Oct 2026)
#   <v-r>-<arch>     e.g. 158.0.8127.88-448874-x86_64   (since 2026-10-04)
# Looking releases up by bare <v-r> only silently stopped matching anything
# after the switch (the updater read "no release yet" for six weeks). Both are
# accepted now, the arch-suffixed form preferred. The pure functions are pinned
# by verify/lib/release-tag-test.sh (checks.*.release-tag).
#
# This file decides NAMES only. Whether a release is trustworthy is decided by
# layer 3 of verify/10-verify-supply-chain.sh, never here.

RELEASE_VR_RE='^[0-9]+(\.[0-9]+){3}-[0-9]+$'

# release_tag_candidates <v-r> <arch>  -> candidate tags, most likely first
release_tag_candidates() {
  printf '%s\n' "$1-$2" "$1"
}

# release_tag_vr <tag> <arch>  -> the v-r a tag stands for; fails (rc 1) for a
# tag that is not a v-r shape, including the OTHER arch's suffixed tag.
release_tag_vr() {
  local v="${1%-"$2"}"
  printf '%s\n' "$v" | grep -Eq "$RELEASE_VR_RE" || return 1
  printf '%s\n' "$v"
}

# release_resolve_tag <v-r> <arch> <owner/repo>  -> the existing release tag
# for this v-r on this arch; fails (rc 1) when no candidate exists.
release_resolve_tag() {
  local t
  for t in $(release_tag_candidates "$1" "$2"); do
    if gh release view "$t" --repo "$3" --json tagName >/dev/null 2>&1; then
      printf '%s\n' "$t"
      return 0
    fi
  done
  return 1
}
