# Parser for `rpmkeys -Kv` output -- the ONE place that knows its text format.
# Sourced, not executed. Used by verify/10-verify-supply-chain.sh and by
# lib/verify.nix (the pure, in-build re-verification), so the two can never
# drift apart again.
#
# rpm has changed this format between releases (a 32-bit "key ID f47b3e41"
# became "key fingerprint: <40 hex>" in rpm 6). The contract is pinned by the
# fixtures in verify/testdata/rpmkeys/ and checked by `checks.*.rpm-sig-parser`
# (verify/lib/rpm-sig-test.sh). When a new rpm prints something else:
#   1. add the new output as verify/testdata/rpmkeys/ok-<what>.txt,
#   2. widen the pattern below until `nix flake check` is green.
# Never loosen it so far that a line for a different key, NOKEY or BAD matches.
#
# Fail-closed by construction: an unrecognised format yields NO ok-lines, so
# verification fails loudly instead of passing silently.

# rpm_sig_ok_lines <rpmkeys-output-file> <key-id-8-hex>
#   prints the signature lines that report OK for a key whose id/fingerprint
#   ends in <key-id-8-hex>. Tolerates "key ID <id>", "key ID: <id>",
#   "key fingerprint: <fpr>" and any "<alg> Signature," / "signature," prefix.
rpm_sig_ok_lines() {
  grep -Ei "signature.*key.*${2}: ok" "$1" || true
}

# rpm_sig_bad_lines <rpmkeys-output-file>
#   prints every digest/signature line reported BAD or NOKEY.
#   ("RSA/DSA signature: NOTFOUND" is normal for an EdDSA-only rpm -- not bad.)
rpm_sig_bad_lines() {
  grep -Ei ': (nokey|bad)( |$|\()' "$1" || true
}
