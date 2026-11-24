#!/usr/bin/env bash
# Contract test for verify/lib/release-tag.sh. Offline: `gh` is a shell
# function here that answers from a fixed set of existing tags.
#   usage: release-tag-test.sh <verify-dir>      (dir holding lib/)
set -euo pipefail

verify_dir="${1:?usage: release-tag-test.sh <verify-dir>}"
# shellcheck source=/dev/null
. "$verify_dir/lib/release-tag.sh"

fail=0
check() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else
    echo "FAIL  $1 (want [$2], got [$3])"
    fail=1
  fi
}

NEW=158.0.8127.88-448874
OLD=154.0.8037.97-447729

check "candidates prefer the arch-suffixed tag" \
  "$NEW-x86_64 $NEW" "$(release_tag_candidates "$NEW" x86_64 | tr '\n' ' ' | sed 's/ $//')"

check "suffixed tag -> v-r" "$NEW" "$(release_tag_vr "$NEW-x86_64" x86_64)"
check "bare (old) tag -> v-r" "$OLD" "$(release_tag_vr "$OLD" x86_64)"
check "bare tag -> v-r on aarch64" "$OLD" "$(release_tag_vr "$OLD" aarch64)"
check "other arch's tag is rejected" "REJECTED" "$(release_tag_vr "$NEW-aarch64" x86_64 || echo REJECTED)"
check "junk tag is rejected" "REJECTED" "$(release_tag_vr "nightly" x86_64 || echo REJECTED)"
check "suffix + extra junk is rejected" "REJECTED" "$(release_tag_vr "$NEW-x86_64-rc1" x86_64 || echo REJECTED)"

# gh stand-in: succeeds iff the requested tag is in $EXISTING
gh() { # gh release view <tag> --repo <r> --json tagName
  case " $EXISTING " in *" $3 "*) return 0 ;; *) return 1 ;; esac
}
resolve() { release_resolve_tag "$1" "$2" owner/repo || echo NONE; }

EXISTING="$NEW-x86_64 $NEW-aarch64"
check "resolve: new scheme, x86_64" "$NEW-x86_64" "$(resolve "$NEW" x86_64)"
check "resolve: new scheme, aarch64" "$NEW-aarch64" "$(resolve "$NEW" aarch64)"

EXISTING="$OLD"
check "resolve: old scheme still works" "$OLD" "$(resolve "$OLD" x86_64)"

EXISTING="$NEW $NEW-x86_64"
check "resolve: both exist -> suffixed wins" "$NEW-x86_64" "$(resolve "$NEW" x86_64)"

EXISTING="$NEW-aarch64"
check "resolve: only the other arch exists -> none" "NONE" "$(resolve "$NEW" x86_64)"

EXISTING=""
check "resolve: nothing exists -> none" "NONE" "$(resolve "$NEW" x86_64)"

[ "$fail" -eq 0 ] || {
  echo "release-tag contract broken -- see verify/lib/release-tag.sh"
  exit 1
}
echo "release-tag: all cases OK"
