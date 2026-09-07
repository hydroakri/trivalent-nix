# Pure, offline re-verification of the pinned RPM, in the build graph.
# `$out/trivalent.rpm` only exists if all three layers pass, so mk-trivalent's
# `src` cannot be an unverified RPM. `$out/supply-chain.log` is the transcript
# (it also ships inside the package).
#
#   layer 1  rpm body signature      -- rpmkeys -Kv against the pinned key
#   layer 2  signed repodata         -- gpg --verify repomd.xml.asc, then bind
#            the RPM's sha256 to the <checksum> in the signed primary.xml
#   layer 3  SLSA provenance CONTENT  -- the pinned .intoto bundle attests a
#            subject trivalent-<vr>.<arch>.rpm with this exact sha256, and its
#            signing cert carries the pinned builder / source / branch identity
#
# NOT re-checked here: the Sigstore/Rekor signature chain over the bundle
# (slsa-verifier needs network). Trust in it rides on `intotoHash` being pinned
# -- and verify/10-verify-supply-chain.sh runs the real slsa-verifier before a
# pin is taken.
{
  runCommand,
  fetchurl,
  rpm,
  gnupg,
  jq,
  zstd,
  gzip,
  libxml2,
  coreutils,
  anchors,
  pins,
  arch,
}:
let
  pin = pins.${arch};
  f =
    name: url: hash:
    fetchurl {
      inherit name url;
      sha256 = hash;
    };
  key = f "secureblue.gpg" pins.keyUrl pins.keyHash;
  rpmFile = f "trivalent-${pin.versionRelease}.${arch}.rpm" pin.rpmUrl pin.rpmHash;
  repomd = f "repomd.xml" pin.repomdUrl pin.repomdHash;
  repomdAsc = f "repomd.xml.asc" pin.repomdAscUrl pin.repomdAscHash;
  primary = f "primary.xml.zst" pin.primaryUrl pin.primaryHash;
  intoto = f "multiple.intoto.jsonl" pin.intotoUrl pin.intotoHash;
in
runCommand "trivalent-${pin.versionRelease}-${arch}-verified"
  {
    nativeBuildInputs = [
      rpm
      gnupg
      jq
      zstd
      gzip
      libxml2
      coreutils
    ];
    inherit (anchors)
      fpr
      fprShort
      slsaBuilderId
      slsaSourceUri
      slsaSourceBranch
      ;
    vr = pin.versionRelease;
    rpmSha = pin.rpmSha256;
    inherit arch;
    passAsFile = [ "hdr" ];
    hdr = "trivalent supply-chain verification (pure, offline)";
  }
  ''
    set -euo pipefail
    exec > >(tee log) 2>&1
    fail() { echo "FAIL $*"; exit 1; }
    ver="''${vr%-*}"; rel="''${vr##*-}"
    xp() { xmllint --xpath "$1" "$2" 2>/dev/null; }

    echo "== layer 1: rpm body signature =="
    export GNUPGHOME="$PWD/gpg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --quiet --import ${key}
    got_fpr="$(gpg --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')"
    [ "$got_fpr" = "$fpr" ] || fail "layer1: imported key fpr $got_fpr != anchor $fpr"
    mkdir -p rpmdb
    rpmkeys --dbpath "$PWD/rpmdb" --import ${key}
    rpmkeys --dbpath "$PWD/rpmdb" -Kv ${rpmFile} > l1 || true
    cat l1
    grep -Eqi "signature,? +key (id|fingerprint) +[0-9a-f]*$fprShort: ok" l1 \
      || fail "layer1: no OK signature from key ...$fprShort"
    ! grep -Eqi ': (nokey|bad)( |$|\()' l1 || fail "layer1: a digest/signature reported BAD/NOKEY"
    echo "layer 1 OK"

    echo "== layer 2: signed repodata + primary tie =="
    gpg --homedir "$GNUPGHOME" --status-fd=1 --verify ${repomdAsc} ${repomd} > l2 2>l2.err || { cat l2 l2.err; fail "layer2: gpg --verify repomd.xml.asc failed"; }
    grep -Eq "^\[GNUPG:\] VALIDSIG [0-9A-F]+ .* $fpr\$" l2 \
      || { cat l2; fail "layer2: repomd.xml is not a VALIDSIG whose primary key is $fpr"; }

    pcs="$(xp 'string(//*[local-name()="data"][@type="primary"]/*[local-name()="checksum"])' ${repomd})"
    [ "$pcs" = "$(sha256sum ${primary} | cut -d' ' -f1)" ] \
      || fail "layer2: primary.xml checksum in signed repomd ($pcs) != the pinned primary file"

    magic="$(od -An -tx1 -N4 ${primary} | tr -d ' \n')"
    case "$magic" in
      28b52ffd*) zstd -dc ${primary} > primary.xml ;;
      1f8b*)     gzip -dc ${primary} > primary.xml ;;
      *)         cp ${primary} primary.xml ;;
    esac
    q='//*[local-name()="package"][*[local-name()="name"]="trivalent"][*[local-name()="arch"]="'"$arch"'"]'
    q="$q[*[local-name()=\"version\"][@ver=\"$ver\"][@rel=\"$rel\"]]"
    cs="$(xp "string($q/*[local-name()=\"checksum\"])" primary.xml)"
    [ -n "$cs" ] || fail "layer2: signed repodata has no trivalent-$vr.$arch"
    [ "$cs" = "$rpmSha" ] || fail "layer2: repodata lists trivalent-$vr checksum $cs, not $rpmSha"
    echo "layer 2 OK (signed repodata attests $rpmSha)"

    echo "== layer 3: SLSA provenance content =="
    jq -r '.dsseEnvelope.payload' ${intoto} | base64 -d > statement.json
    jq -e --arg n "trivalent-$vr.$arch.rpm" --arg h "$rpmSha" \
      '.subject[] | select(.name==$n) | .digest.sha256==$h' statement.json >/dev/null \
      || fail "layer3: provenance has no subject trivalent-$vr.$arch.rpm digest $rpmSha"
    jq -r '.verificationMaterial.certificate.rawBytes' ${intoto} | base64 -d > cert.der
    for s in "$slsaBuilderId" "$slsaSourceUri" "refs/heads/$slsaSourceBranch"; do
      grep -qaF "$s" cert.der || fail "layer3: signing cert does not carry '$s'"
    done
    echo "layer 3 OK (provenance binds this RPM to $slsaBuilderId)"

    mkdir -p "$out"
    cp ${rpmFile} "$out/trivalent.rpm"
    { cat "$hdrPath"; echo; echo "version-release : $vr"; echo "arch            : $arch";
      echo "rpm sha256      : $rpmSha"; echo "signing key     : $fpr";
      echo "slsa builder    : $slsaBuilderId"; echo;
      echo "RESULT: PASS (layers 1+2+3, offline; Sigstore chain carried by intotoHash pin)"; } > "$out/supply-chain.log"
    cat log >> "$out/supply-chain.log"
    echo "RESULT: PASS"
  ''
