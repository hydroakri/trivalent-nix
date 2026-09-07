#!/usr/bin/env bash
# 10-verify-supply-chain.sh <version-release> <arch> [<rpm-path>]
#
#   version-release : e.g. 152.0.7977.82-447128   (== the GitHub release tag)
#   arch            : x86_64 | aarch64
#   rpm-path        : optional; if omitted the RPM is downloaded from the location
#                     named in the (signature-verified) repodata.
#
# Runs THREE independent checks. "Verified" == all three return success AND every
# key involved traces to SECUREBLUE_FPR. Two-of-three is a FAIL. There is exactly
# one code path that prints "RESULT: PASS".
#
#   layer 1  rpm package body signature   (rpmkeys -Kv against a temp rpmdb)
#   layer 2  repodata detached signature  (gpg --verify repomd.xml.asc) + bind the
#            RPM's sha256 to the <checksum> in the signed primary.xml
#   layer 3  SLSA provenance              (slsa-verifier verify-artifact, builder
#            + source-uri + source-branch all pinned)
#
# Exit codes:
#   0    RESULT: PASS
#   11   layer 1 failed
#   12   layer 2 failed
#   13   layer 3 failed (provenance present but did not verify)
#   30   layer 3: provenance FORMAT CHANGED -- .intoto.jsonl gone but some other
#        attestation exists. Distinct from "missing" on purpose (failure mode F2).
#   31   layer 3: provenance MISSING -- no attestation of any kind.
#   40   key material did not match SECUREBLUE_FPR / SECUREBLUE_GPG_SHA256
#   2    usage
#
# On any outcome, verify/logs/<version-release>/ is written and is meant to be
# copied verbatim into the package $out (see lib/mk-trivalent.nix).

NEED_TOOLS="curl gpg gh jq xmllint rpmkeys slsa-verifier sha256sum gzip zstd"
# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

VR="${1:-}"
ARCH="${2:-}"
RPM_IN="${3:-}"
[ -n "$VR" ] && [ -n "$ARCH" ] || die "usage: $0 <version-release> <x86_64|aarch64> [rpm-path]" 2
case "$ARCH" in x86_64 | aarch64) ;; *) die "bad arch: $ARCH" 2 ;; esac

# default log root; overridable so the negative tests don't clobber the
# committed log for the pinned version.
LOGDIR="${TRIVALENT_LOG_ROOT:-$VERIFY_DIR/logs}/$VR"
mkdir -p "$LOGDIR"
: >"$LOGDIR/layer1.txt"
: >"$LOGDIR/layer2.txt"
: >"$LOGDIR/layer3.txt"
FPR_LC="$(printf '%s' "$SECUREBLUE_FPR" | tr 'A-Z' 'a-z')"
KEYID16="${FPR_LC: -16}"
KEYID8="${FPR_LC: -8}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

# ---------------------------------------------------------------- verified key
log "acquiring signing key and checking it against fingerprint.env"
fetch "$SECUREBLUE_REPO_BASEURL/secureblue.gpg" -o "$work/key.gpg" || die "cannot fetch secureblue.gpg" 40
key_sha="$(sha256sum "$work/key.gpg" | cut -d' ' -f1)"
[ "$key_sha" = "$SECUREBLUE_GPG_SHA256" ] || die "secureblue.gpg sha256 $key_sha != pinned $SECUREBLUE_GPG_SHA256 (F1: do not proceed)" 40
gpg --quiet --import "$work/key.gpg" 2>/dev/null || die "gpg import failed" 40
key_fpr="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
[ "$key_fpr" = "$SECUREBLUE_FPR" ] || die "key fpr $key_fpr != pinned $SECUREBLUE_FPR (F1: do not proceed)" 40
gpg --export "$SECUREBLUE_FPR" >"$work/kr.gpg"
log "key OK: $key_fpr (sha256 $key_sha)"

# ============================================================ LAYER 2 (first:
# it yields the repodata-blessed sha256 that layers 1 & 3 are then bound to)
# NB: errexit is OFF inside every layer group -- a failing sub-command must fail
# THAT LAYER and let the script continue to the verdict, never abort the run.
L2=1
set +e
{
  echo "== layer 2: repodata detached signature =="
  fetch "$SECUREBLUE_REPO_BASEURL/repodata/repomd.xml" -o "$work/repomd.xml"
  fetch "$SECUREBLUE_REPO_BASEURL/repodata/repomd.xml.asc" -o "$work/repomd.xml.asc"
  echo "-- gpg --verify repomd.xml.asc repomd.xml"
  gpg --homedir "$GNUPGHOME" --status-fd=3 --verify "$work/repomd.xml.asc" "$work/repomd.xml" 3>"$work/g.status" 2>&1
  gv_rc=$?
  cat "$work/g.status"
  validsig_primary="$(awk '/^\[GNUPG:\] VALIDSIG /{print $NF}' "$work/g.status")"
  echo "VALIDSIG primary key: ${validsig_primary:-<none>}  rc=$gv_rc"
  if [ $gv_rc -ne 0 ] || [ "$validsig_primary" != "$SECUREBLUE_FPR" ]; then
    echo "FAIL: repomd.xml signature not a valid signature from $SECUREBLUE_FPR"
  else
    # primary.xml, verified by the checksum inside the *signed* repomd.xml
    pl="$(repomd_primary_location "$work/repomd.xml")"
    p_href="$(printf '%s' "$pl" | cut -f1)"
    p_ct="$(printf '%s' "$pl" | cut -f2)"
    p_cs="$(printf '%s' "$pl" | cut -f3)"
    fetch "$SECUREBLUE_REPO_BASEURL/$p_href" -o "$work/primary.bin"
    got="$("${p_ct}sum" "$work/primary.bin" | cut -d' ' -f1)"
    echo "primary.xml $p_ct: expected $p_cs got $got"
    if [ "$got" != "$p_cs" ]; then
      echo "FAIL: primary.xml checksum mismatch"
    else
      decompress_to "$work/primary.bin" "$work/primary.xml"
      row="$(repomd_newest_pkg "$work/primary.xml" trivalent "$ARCH")" || {
        echo "FAIL: no trivalent/$ARCH in primary.xml"
        row=""
      }
      if [ -n "$row" ]; then
        r_vr="$(printf '%s' "$row" | cut -f1)"
        r_loc="$(printf '%s' "$row" | cut -f2)"
        r_ct="$(printf '%s' "$row" | cut -f3)"
        r_cs="$(printf '%s' "$row" | cut -f4)"
        echo "repodata trivalent: $r_vr  loc=$r_loc  $r_ct=$r_cs"
        if [ "$r_vr" != "$VR" ]; then
          echo "FAIL: repodata trivalent is $r_vr, not the requested $VR"
        elif [ "$r_ct" != "sha256" ]; then
          echo "FAIL: repodata checksum type is $r_ct, expected sha256"
        else
          REPODATA_SHA256="$r_cs"
          RPM_LOC="$r_loc"
          echo "OK: layer 2 verified; repodata-blessed sha256 = $REPODATA_SHA256"
          L2=0
        fi
      fi
    fi
  fi
} >"$LOGDIR/layer2.txt" 2>&1
set -e
[ "$L2" -eq 0 ] && log "layer 2 PASS" || log "layer 2 FAIL (see $LOGDIR/layer2.txt)"

# --------------------------------------------------------- obtain the RPM
if [ -z "$RPM_IN" ]; then
  [ -n "${RPM_LOC:-}" ] || RPM_LOC="Packages/trivalent-$VR.$ARCH.rpm"
  RPM_IN="$work/$(basename "$RPM_LOC")"
  log "downloading $SECUREBLUE_REPO_BASEURL/$RPM_LOC"
  fetch "$SECUREBLUE_REPO_BASEURL/$RPM_LOC" -o "$RPM_IN" || die "cannot download RPM" 1
fi
[ -f "$RPM_IN" ] || die "rpm not found: $RPM_IN" 2
RPM_SHA256="$(sha256sum "$RPM_IN" | cut -d' ' -f1)"
log "rpm: $RPM_IN  sha256=$RPM_SHA256"

# ============================================================ LAYER 1
L1=1
set +e
{
  echo "== layer 1: rpm package body signature =="
  echo "-- rpmkeys --dbpath (temp) --import <verified key>"
  rpmkeys --dbpath "$work/rpmdb" --import "$work/key.gpg"
  echo "-- rpmkeys --dbpath (temp) -Kv $RPM_IN"
  rpmkeys --dbpath "$work/rpmdb" -Kv "$RPM_IN" >"$work/rk.out" 2>&1
  rk_rc=$?
  cat "$work/rk.out"
  echo "rpmkeys rc=$rk_rc"
  # rpm-sequoia prints the short (32-bit) key id: "...Signature, key ID f47b3e41: OK"
  # older rpm prints 64-bit; match KEYID8 as a suffix of the hex token before ": OK".
  ok_sig="$(grep -Ei "signature,? +key (id|fingerprint) +[0-9a-f]*${KEYID8}: ok" "$work/rk.out" || true)"
  # any digest/signature line reported BAD, or the key not present (NOKEY).
  # ("RSA/DSA signature: NOTFOUND" is normal for an EdDSA-only rpm -- not a failure.)
  bad="$(grep -Ei ': (nokey|bad)( |$|\()' "$work/rk.out" || true)"
  echo "matched OK sig lines : ${ok_sig:-<none>}"
  echo "bad / nokey lines    : ${bad:-<none>}"
  if [ "$rk_rc" -eq 0 ] && [ -n "$ok_sig" ] && [ -z "$bad" ]; then
    echo "OK: layer 1 verified (rpm body signed by key ...$KEYID8, traces to $SECUREBLUE_FPR)"
    L1=0
  else
    echo "FAIL: rpm body not verifiably signed by ...$KEYID8"
  fi
} >"$LOGDIR/layer1.txt" 2>&1
set -e
[ "$L1" -eq 0 ] && log "layer 1 PASS" || log "layer 1 FAIL (see $LOGDIR/layer1.txt)"

# cross-tie layer 1 <-> layer 2
if [ "$L1" -eq 0 ] && [ "$L2" -eq 0 ] && [ "$RPM_SHA256" != "$REPODATA_SHA256" ]; then
  { echo "FAIL: rpm sha256 $RPM_SHA256 != repodata-blessed $REPODATA_SHA256"; } >>"$LOGDIR/layer2.txt"
  L2=1
  log "layer 2 FAIL: downloaded RPM does not match the signed repodata checksum"
fi

# ============================================================ LAYER 3
L3=1
L3CODE=13
set +e
{
  echo "== layer 3: SLSA provenance =="
  assets="$(gh release view "$VR" --repo "$TRIVALENT_GH_REPO" --json assets --jq '.assets[].name' 2>/dev/null || true)"
  echo "release $VR assets:"
  printf '  %s\n' $assets
  if printf '%s\n' $assets | grep -qx 'multiple.intoto.jsonl'; then
    gh release download "$VR" --repo "$TRIVALENT_GH_REPO" --pattern 'multiple.intoto.jsonl' --dir "$work" --clobber
    echo "-- slsa-verifier verify-artifact"
    slsa-verifier verify-artifact "$RPM_IN" \
      --provenance-path "$work/multiple.intoto.jsonl" \
      --source-uri "$SLSA_SOURCE_URI" \
      --source-branch "$SLSA_SOURCE_BRANCH" \
      --builder-id "$SLSA_BUILDER_ID"
    sv_rc=$?
    echo "slsa-verifier rc=$sv_rc"
    if [ $sv_rc -eq 0 ]; then
      echo "OK: layer 3 verified"
      L3=0
    else
      echo "FAIL: provenance did not verify"
      L3CODE=13
    fi
  elif printf '%s\n' $assets | grep -qE '\.(intoto\.jsonl|sigstore|sigstore\.json|att|bundle)$' ||
    gh api "repos/$TRIVALENT_GH_REPO/attestations/sha256:$RPM_SHA256" >/dev/null 2>&1; then
    echo "FAIL: 'multiple.intoto.jsonl' is absent but another attestation form is present."
    echo "      This is F2 (provenance format change), NOT missing provenance."
    echo "      The verifier must be updated deliberately; refusing to pass."
    L3CODE=30
  else
    echo "FAIL: no provenance of any kind for release $VR."
    L3CODE=31
  fi
} >"$LOGDIR/layer3.txt" 2>&1
set -e
[ "$L3" -eq 0 ] && log "layer 3 PASS" || log "layer 3 FAIL rc=$L3CODE (see $LOGDIR/layer3.txt)"

# ============================================================ verdict
RESULT="FAIL"
{
  echo "version-release : $VR"
  echo "arch            : $ARCH"
  echo "rpm             : $(basename "$RPM_IN")"
  echo "rpm sha256      : $RPM_SHA256"
  echo "repodata sha256 : ${REPODATA_SHA256:-<layer2 failed>}"
  echo "signing key fpr : $key_fpr  (pinned $SECUREBLUE_FPR)"
  echo "slsa builder    : $SLSA_BUILDER_ID"
  echo "layer 1 (rpm sig)      exit: $([ "$L1" -eq 0 ] && echo 0 || echo 11)"
  echo "layer 2 (repodata sig) exit: $([ "$L2" -eq 0 ] && echo 0 || echo 12)"
  echo "layer 3 (provenance)   exit: $([ "$L3" -eq 0 ] && echo 0 || echo "$L3CODE")"
} >"$LOGDIR/summary.txt"

if [ "$L1" -eq 0 ] && [ "$L2" -eq 0 ] && [ "$L3" -eq 0 ]; then
  RESULT="PASS"
  echo "RESULT: PASS" | tee -a "$LOGDIR/summary.txt"

  sri() { nix hash to-sri --type sha256 "$1" 2>/dev/null || nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$1"; }
  p_href="$(repomd_primary_location "$work/repomd.xml" | cut -f1)"
  ver="${VR%-*}"

  cat <<EOF

--- paste into pins.nix under $ARCH = { ... }; ---
    versionRelease = "$VR";
    version = "$ver";
    rpmUrl = "$SECUREBLUE_REPO_BASEURL/${RPM_LOC:-Packages/trivalent-$VR.$ARCH.rpm}";
    rpmHash = "$(sri "$RPM_SHA256")";
    rpmSha256 = "$RPM_SHA256";
    repomdUrl = "$SECUREBLUE_REPO_BASEURL/repodata/repomd.xml";
    repomdHash = "$(sri "$(sha256sum "$work/repomd.xml" | cut -d' ' -f1)")";
    repomdAscUrl = "$SECUREBLUE_REPO_BASEURL/repodata/repomd.xml.asc";
    repomdAscHash = "$(sri "$(sha256sum "$work/repomd.xml.asc" | cut -d' ' -f1)")";
    primaryUrl = "$SECUREBLUE_REPO_BASEURL/$p_href";
    primaryHash = "$(sri "$(sha256sum "$work/primary.bin" | cut -d' ' -f1)")";
    intotoUrl = "https://github.com/$TRIVALENT_GH_REPO/releases/download/$VR/multiple.intoto.jsonl";
    intotoHash = "$(sri "$(sha256sum "$work/multiple.intoto.jsonl" | cut -d' ' -f1)")";
--- keyHash (constant, only if it changed): $(sri "$(sha256sum "$work/key.gpg" | cut -d' ' -f1)") ---
EOF
  exit 0
fi

# ordered: report the earliest failed layer
if [ "$L1" -ne 0 ]; then
  echo "RESULT: FAIL layer1" | tee -a "$LOGDIR/summary.txt"
  exit 11
fi
if [ "$L2" -ne 0 ]; then
  echo "RESULT: FAIL layer2" | tee -a "$LOGDIR/summary.txt"
  exit 12
fi
echo "RESULT: FAIL layer3" | tee -a "$LOGDIR/summary.txt"
exit "$L3CODE"
