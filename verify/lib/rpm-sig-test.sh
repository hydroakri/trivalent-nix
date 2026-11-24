#!/usr/bin/env bash
# Contract test for verify/lib/rpm-sig.sh against recorded `rpmkeys -Kv` output.
#   usage: rpm-sig-test.sh <verify-dir>      (dir holding lib/ and testdata/)
#
# Every verify/testdata/rpmkeys/ok-*.txt   MUST verify  (sig OK, nothing BAD)
# Every verify/testdata/rpmkeys/reject-*.txt MUST NOT verify
# so adding a fixture needs no change here. Runs offline, no rpm needed.
set -euo pipefail

verify_dir="${1:?usage: rpm-sig-test.sh <verify-dir>}"
# shellcheck source=/dev/null
. "$verify_dir/lib/rpm-sig.sh"

fixtures="$verify_dir/testdata/rpmkeys"
KEYID8=f47b3e41
fail=0
n=0

verifies() { # <file> -> 0 iff the parser would accept it
  [ -n "$(rpm_sig_ok_lines "$1" "$KEYID8")" ] && [ -z "$(rpm_sig_bad_lines "$1")" ]
}

for f in "$fixtures"/ok-*.txt; do
  [ -e "$f" ] || continue
  n=$((n + 1))
  if verifies "$f"; then echo "PASS  accepts  $(basename "$f")"; else
    echo "FAIL  must accept  $(basename "$f")"
    fail=1
  fi
done
for f in "$fixtures"/reject-*.txt; do
  [ -e "$f" ] || continue
  n=$((n + 1))
  if verifies "$f"; then
    echo "FAIL  must reject  $(basename "$f")"
    fail=1
  else echo "PASS  rejects  $(basename "$f")"; fi
done

[ "$n" -gt 0 ] || {
  echo "FAIL  no fixtures found in $fixtures"
  exit 1
}
[ "$fail" -eq 0 ] || {
  echo "rpm-sig parser contract broken -- see verify/lib/rpm-sig.sh header"
  exit 1
}
echo "rpm-sig parser: $n fixtures OK"
