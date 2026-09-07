#!/usr/bin/env bash
# 40-review.sh -- the independent-review layer (spec section 4). Run after ANY
# change to 00/10/20 or fingerprint.env, however small. It does not touch the
# logic it inspects. Three questions, three exit-code checks:
#
#   R1 definition drift : every change to SECUREBLUE_FPR in git history has a
#                         corresponding dated KEY-PROVENANCE.md row.
#   R2 coverage         : 20-version-map.sh still reaches BOTH the "repomd behind
#                         GitHub" (delay) branch AND the "repomd ahead / tag
#                         absent" reverse branch -- not just the common one.
#   R3 criterion        : 10-verify-supply-chain.sh passes iff L1&&L2&&L3 (AND,
#                         all three), and "RESULT: PASS" is emitted on exactly
#                         one code path.
#
# Exit 0 iff all three hold.

set -uo pipefail
cd "$(dirname "$0")/.."
V=verify
fail=0
say() { printf '%-4s %s\n' "$1" "$2"; }
bad() {
  say "FAIL" "$1"
  fail=1
}
good() { say "ok" "$1"; }

# ---- R1: definition drift ------------------------------------------------
echo "== R1: fingerprint definition drift =="
if [ -d .git ]; then
  # every distinct SECUREBLUE_FPR= value that ever appeared in history
  mapfile -t fprs < <(git log -p --all -- "$V/fingerprint.env" 2>/dev/null |
    grep -E '^\+SECUREBLUE_FPR=' | sed 's/^+SECUREBLUE_FPR=//' | sort -u)
  if [ "${#fprs[@]}" -le 1 ]; then
    good "SECUREBLUE_FPR has had a single value in history (${fprs[0]:-<none>})"
  else
    good "SECUREBLUE_FPR changed ${#fprs[@]} times in history; checking KEY-PROVENANCE.md"
    for f in "${fprs[@]}"; do
      if grep -qF "$f" KEY-PROVENANCE.md 2>/dev/null; then
        good "  $f has a KEY-PROVENANCE.md row"
      else
        bad "  $f has NO KEY-PROVENANCE.md row -- silent fingerprint change"
      fi
    done
  fi
  # current value must match the newest KEY-PROVENANCE.md row
  cur="$(sed -n 's/^SECUREBLUE_FPR=//p' "$V/fingerprint.env")"
  if [ -f KEY-PROVENANCE.md ] && ! tail -n1 KEY-PROVENANCE.md | grep -qF "$cur"; then
    bad "current SECUREBLUE_FPR ($cur) is not the one in the last KEY-PROVENANCE.md row"
  else
    good "current SECUREBLUE_FPR is backed by the latest KEY-PROVENANCE.md row"
  fi
else
  bad "not a git repo -- cannot audit fingerprint history"
fi

# ---- R2: version-map coverage ----------------------------------------------
echo "== R2: version-map branch coverage =="
vm="$V/20-version-map.sh"
grep -q 'exit 20' "$vm" && grep -q 'ahead of the newest listed' "$vm" &&
  good "reverse-inconsistency branch (repodata ahead / tag absent -> 20) present" ||
  bad "reverse-inconsistency branch missing or altered"
grep -q 'older "$A" "$B"' "$vm" && grep -q 'exit 21' "$vm" &&
  good "delay branch (repodata behind -> retry -> 21) present" ||
  bad "delay branch missing or altered"
grep -Eq 'exit 22' "$vm" &&
  good "unparseable branch (-> 22) present" ||
  bad "unparseable branch missing"
# the two disagreement directions must be DIFFERENT exit codes
grep -q 'exit 20' "$vm" && grep -q 'exit 21' "$vm" &&
  good "delay (21) and tampering (20) are distinct codes" ||
  bad "delay and tampering not distinguished"

# ---- R3: pass-criterion validity ----------------------------------------
echo "== R3: 10-verify pass criterion =="
sc="$V/10-verify-supply-chain.sh"
gate="$(grep -n 'L1.*-eq 0.*&&.*L2.*-eq 0.*&&.*L3.*-eq 0' "$sc" || true)"
if [ -n "$gate" ]; then
  good "final gate is L1 && L2 && L3 (all three): ${gate%%:*}"
else
  bad "final gate is not a three-way AND of L1,L2,L3"
fi
n_pass="$(grep -c 'RESULT: PASS' "$sc")"
# one in the tee that prints it, plus none else that could reach exit 0
emit="$(grep -n 'echo "RESULT: PASS"' "$sc" || true)"
if [ "$(printf '%s\n' "$emit" | grep -c .)" -eq 1 ]; then
  good "\"RESULT: PASS\" emitted on exactly one code path: ${emit%%:*}"
else
  bad "\"RESULT: PASS\" emitted on $(printf '%s\n' "$emit" | grep -c .) paths"
fi
grep -Eq '\|\|.*(L1|L2|L3).*-eq 0|(-eq 0).*\|\|.*(-eq 0)' "$sc" &&
  bad "an OR of layer results is present near the gate -- inspect manually" ||
  good "no OR-of-layers shortcut near the gate"
# each layer sets its L var to 0 only inside its own OK branch
for n in 1 2 3; do
  c="$(grep -c "L$n=0" "$sc")"
  [ "$c" -eq 1 ] && good "L$n is set to 0 exactly once" || bad "L$n set to 0 $c times (expected 1)"
done

# ---- R4: Sigstore trusted-root pin integrity ---------------------------
echo "== R4: Sigstore trusted-root pin =="
trf="$V/sigstore-trusted-root.json"
pinned="$(sed -n 's/.*sigstoreTrustedRootSha256 = "\([0-9a-f]*\)".*/\1/p' pins.nix)"
if [ -f "$trf" ] && [ "$(sha256sum "$trf" | cut -d' ' -f1)" = "$pinned" ]; then
  good "sigstore-trusted-root.json on disk matches pins.nix sigstoreTrustedRootSha256"
else
  bad "sigstore-trusted-root.json sha256 != pins.nix sigstoreTrustedRootSha256"
fi
if [ -d .git ]; then
  # every trusted-root value that ever appeared must have a KEY-PROVENANCE.md row
  mapfile -t trs < <(git log -p --all -- "$trf" pins.nix 2>/dev/null |
    grep -E '^\+.*sigstoreTrustedRootSha256 = "' | sed 's/.*"\([0-9a-f]*\)".*/\1/' | sort -u)
  if [ "${#trs[@]}" -le 1 ]; then
    good "sigstoreTrustedRootSha256 has had a single value in history"
  else
    for t in "${trs[@]}"; do
      grep -qF "$t" KEY-PROVENANCE.md 2>/dev/null &&
        good "  trusted-root $t has a KEY-PROVENANCE.md row" ||
        bad "  trusted-root $t rotated without a KEY-PROVENANCE.md row (see MAINTENANCE.md)"
    done
  fi
fi

echo
[ "$fail" -eq 0 ] && echo "REVIEW: PASS" || echo "REVIEW: FAIL"
exit "$fail"
