#!/usr/bin/env bash
# 99-negative-tests.sh -- proves the fail-closed paths actually fail closed.
# Each case asserts a specific exit code. Run after touching 00/10/20 or
# fingerprint.env. Needs network (real RPM + real repodata for NEG-1/NEG-3).
#
#   NEG-1  tampered RPM              -> 10-verify exits 11 (layer 1)
#   NEG-2  fingerprint flipped       -> 00-bootstrap exits 40, writes nothing
#   NEG-3a provenance format changed -> 10-verify exits 30  (F2, not "missing")
#   NEG-3b provenance truly absent   -> 10-verify exits 31
#   NEG-4  repodata ahead of GitHub  -> 20-version-map exits 20 (F3 reverse)

set -uo pipefail
cd "$(dirname "$0")/.."
VR="${TRIVALENT_TEST_VR:-152.0.7977.82-447128}"
BASEURL="${SECUREBLUE_REPO_BASEURL:-https://repo.secureblue.dev}"
pass=0 fail=0
ok() {
  echo "PASS  $1"
  pass=$((pass + 1))
}
no() {
  echo "FAIL  $1"
  fail=$((fail + 1))
}
expect() { # <label> <wanted-rc> <got-rc>
  if [ "$2" = "$3" ]; then ok "$1 (rc=$3)"; else no "$1 (wanted $2, got $3)"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; git checkout -q -- verify/fingerprint.env 2>/dev/null || true' EXIT

# ---- NEG-1 ---------------------------------------------------------------
echo "== NEG-1: tampered RPM =="
curl -fsSL -o "$tmp/t.rpm" "$BASEURL/Packages/trivalent-$VR.x86_64.rpm"
printf 'XXXX' | dd of="$tmp/t.rpm" bs=1 seek=100000 conv=notrunc count=4 status=none
TRIVALENT_LOG_ROOT="$tmp/logs" ./verify/10-verify-supply-chain.sh "$VR" x86_64 "$tmp/t.rpm" >"$tmp/n1.log" 2>&1
expect "tampered RPM -> layer 1" 11 $?

# ---- NEG-2 ---------------------------------------------------------------
echo "== NEG-2: fingerprint flip =="
cp KEY-PROVENANCE.md "$tmp/kp.before" 2>/dev/null || : >"$tmp/kp.before"
sed -i 's/\(SECUREBLUE_FPR=26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E4\)1/\12/' verify/fingerprint.env
./verify/00-bootstrap-key.sh >"$tmp/n2.log" 2>&1
rc=$?
git checkout -q -- verify/fingerprint.env
expect "fingerprint flip -> refuse" 40 "$rc"
if cmp -s "$tmp/kp.before" KEY-PROVENANCE.md 2>/dev/null || [ ! -s KEY-PROVENANCE.md ]; then
  ok "NEG-2 wrote nothing to KEY-PROVENANCE.md"
else
  no "NEG-2 modified KEY-PROVENANCE.md"
fi

# ---- NEG-3: F2 via a gh shim that only rewrites `release view --json assets`
echo "== NEG-3: provenance format change vs absence =="
mkdir -p "$tmp/shim"
cat >"$tmp/shim/gh" <<'SH'
#!/usr/bin/env bash
real="$(PATH="${PATH#*"$FAKE_GH_DIR":}" command -v gh)"
if [ "$1" = "release" ] && [ "$2" = "view" ] && printf '%s ' "$@" | grep -q -- '--json assets'; then
  printf '%s\n' "$FAKE_ASSETS"
  exit 0
fi
exec "$real" "$@"
SH
chmod +x "$tmp/shim/gh"
export FAKE_GH_DIR="$tmp/shim"
# 3a: a different attestation form is present -> format changed -> 30
FAKE_ASSETS='trivalent.sigstore.json' PATH="$tmp/shim:$PATH" \
  TRIVALENT_LOG_ROOT="$tmp/logs" ./verify/10-verify-supply-chain.sh "$VR" x86_64 >"$tmp/n3a.log" 2>&1
expect "F2 format changed -> 30" 30 $?
# 3b: nothing at all -> missing -> 31
FAKE_ASSETS='' PATH="$tmp/shim:$PATH" \
  TRIVALENT_LOG_ROOT="$tmp/logs" ./verify/10-verify-supply-chain.sh "$VR" x86_64 >"$tmp/n3b.log" 2>&1
expect "F2 truly absent -> 31" 31 $?
unset FAKE_GH_DIR

# ---- NEG-4: F3 reverse inconsistency (repodata advertises a tag GH lacks) ----
echo "== NEG-4: repodata ahead of GitHub =="
fx="$tmp/fixrepo"
mkdir -p "$fx/repodata"
cat >"$fx/repodata/primary.xml" <<XML
<?xml version="1.0"?>
<metadata xmlns="http://linux.duke.edu/metadata/common" xmlns:rpm="http://linux.duke.edu/metadata/rpm" packages="1">
 <package type="rpm">
  <name>trivalent</name><arch>x86_64</arch>
  <version epoch="0" ver="999.0.0.0" rel="999999"/>
  <checksum type="sha256" pkgid="YES">deadbeef</checksum>
  <location href="Packages/trivalent-999.0.0.0-999999.x86_64.rpm"/>
 </package>
</metadata>
XML
sz=$(wc -c <"$fx/repodata/primary.xml")
csum=$(sha256sum "$fx/repodata/primary.xml" | cut -d' ' -f1)
cat >"$fx/repodata/repomd.xml" <<XML
<?xml version="1.0"?>
<repomd xmlns="http://linux.duke.edu/metadata/repo">
 <data type="primary">
  <checksum type="sha256">$csum</checksum>
  <location href="repodata/primary.xml"/><size>$sz</size>
 </data>
</repomd>
XML
# serve the fixture over http (nixpkgs curl disables file://)
command -v busybox >/dev/null || {
  echo "SKIP: need busybox for the fixture HTTP server (nix shell nixpkgs#busybox)"
  exit 0
}
busybox httpd -f -p 127.0.0.1:8973 -h "$fx" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null; rm -rf "$tmp"; git checkout -q -- verify/fingerprint.env 2>/dev/null || true' EXIT
for _ in $(seq 20); do
  curl -fsS -o /dev/null "http://127.0.0.1:8973/repodata/repomd.xml" 2>/dev/null && break
  sleep 0.2
done
SECUREBLUE_REPO_BASEURL="http://127.0.0.1:8973" VMAP_RETRIES=0 \
  ./verify/20-version-map.sh x86_64 >"$tmp/n4.log" 2>&1
expect "repodata tag absent on GitHub -> 20" 20 $?
kill $srv 2>/dev/null || true

echo
echo "negative tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
