#!/usr/bin/env bash
# 00-bootstrap-key.sh -- initialisation gate for the secureblue signing key.
#
# Run once, and again whenever the key rotates. It does NOT run as part of the
# per-update flow; it is the human-in-the-loop step that authorises the
# hard-coded values in fingerprint.env.
#
# It acquires the key from two INDEPENDENT channels and refuses to proceed
# unless both agree with each other AND with fingerprint.env:
#
#   Channel A : https://repo.secureblue.dev/secureblue.gpg          (R2 / CDN)
#   Channel B : secureblue/secureblue @ committed path in git       (GitHub, diff host+path)
#   Cross     : secureblue/Trivalent build.yml still names the fpr   (source-of-truth liveness)
#
# Exit codes:
#   0   all channels agree with fingerprint.env; KEY-PROVENANCE.md row appended
#   40  a channel disagrees / fingerprint mismatch  -> INITIALISATION INCOMPLETE
#   41  could not fetch a channel (network) -- retry, do not treat as adopt
#
# There is deliberately NO code path that writes a new fingerprint into
# fingerprint.env. Adopting a rotated key is a manual edit + KEY-PROVENANCE.md
# entry, reviewed by a human. (failure mode F1)

NEED_TOOLS="curl gpg sha256sum gh jq"
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

fail=0
note() { printf '  %-10s %s\n' "$1" "$2"; }

log "channel A: $SECUREBLUE_REPO_BASEURL/secureblue.gpg"
if ! fetch "$SECUREBLUE_REPO_BASEURL/secureblue.gpg" -o "$work/A.gpg"; then
  die "could not fetch channel A" 41
fi

log "channel B: github $SECUREBLUE_GH_REPO :: $SECUREBLUE_GPG_COMMITTED_PATH"
if ! gh api "repos/$SECUREBLUE_GH_REPO/contents/$SECUREBLUE_GPG_COMMITTED_PATH" \
  -H "Accept: application/vnd.github.raw" >"$work/B.gpg" 2>"$work/B.err"; then
  cat "$work/B.err" >&2
  die "could not fetch channel B" 41
fi

a_sha="$(sha256sum "$work/A.gpg" | cut -d' ' -f1)"
b_sha="$(sha256sum "$work/B.gpg" | cut -d' ' -f1)"
note "A sha256" "$a_sha"
note "B sha256" "$b_sha"
note "pinned" "$SECUREBLUE_GPG_SHA256"

[ "$a_sha" = "$b_sha" ] || {
  note "MISMATCH" "channel A and B differ"
  fail=1
}
[ "$a_sha" = "$SECUREBLUE_GPG_SHA256" ] || {
  note "MISMATCH" "channel A != pinned sha256"
  fail=1
}

# Fingerprint from the actual key bytes (channel A).
gpg --quiet --import "$work/A.gpg" 2>/dev/null || {
  note "MISMATCH" "gpg could not import channel A"
  fail=1
}
seen_fpr="$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
note "key fpr" "${seen_fpr:-<none>}"
note "pinned" "$SECUREBLUE_FPR"
[ "$seen_fpr" = "$SECUREBLUE_FPR" ] || {
  note "MISMATCH" "key fingerprint != pinned"
  fail=1
}

# Cross-check: the fingerprint still appears verbatim in the upstream build workflow.
log "cross-check: $TRIVALENT_GH_REPO build.yml names the fingerprint"
by="$(gh api "repos/$TRIVALENT_GH_REPO/contents/.github/workflows/build.yml" \
  -H "Accept: application/vnd.github.raw" 2>/dev/null || true)"
if printf '%s' "$by" | grep -qF "$SECUREBLUE_FPR"; then
  note "build.yml" "contains $SECUREBLUE_FPR"
else
  note "MISMATCH" "build.yml no longer contains the pinned fingerprint"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  cat >&2 <<EOF

INITIALISATION INCOMPLETE -- needs human cross-check.
One or more channels disagree with verify/fingerprint.env. This is what a key
rotation AND a key compromise both look like; they are not distinguished here.
Do NOT edit fingerprint.env until at least two independent channels have been
confirmed by a human to show the same new value, and KEY-PROVENANCE.md records it.
EOF
  exit 40
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
prov="$REPO_ROOT/KEY-PROVENANCE.md"
[ -f "$prov" ] || printf '# KEY-PROVENANCE\n\nAppend-only. Each row = one confirmation that the pinned values match reality.\n\n| date (UTC) | fingerprint | gpg sha256 | channel A | channel B | cross-check | by |\n|---|---|---|---|---|---|---|\n' >"$prov"
printf '| %s | `%s` | `%s` | repo.secureblue.dev OK | github %s OK | build.yml OK | %s |\n' \
  "$ts" "$SECUREBLUE_FPR" "$SECUREBLUE_GPG_SHA256" "$SECUREBLUE_GH_REPO" \
  "${BOOTSTRAP_CONFIRMED_BY:-$(git config user.name 2>/dev/null || echo unknown)}" >>"$prov"

log "OK -- all channels agree. Appended confirmation row to KEY-PROVENANCE.md"
exit 0
