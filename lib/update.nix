# The Nix-built unattended updater. `nix run .#update` from a checkout:
#   preflight (F1 halt gates) -> discover -> verify (live) -> rewrite pins.nix
#   -> re-verify offline (nix build .#supply-chain) -> emit updateScript JSON.
#
# It reads pins.nix / verify/fingerprint.env from the WORKING DIRECTORY at run
# time (never a build-time snapshot), orchestrates the existing verify/ scripts
# (the irreducible network poll) behind a clean, dependency-pinned PATH, and
# owns the pins.nix rewrite + machine-readable output. Idempotent; a no-op when
# nothing moved.
#
# Exit codes (the CI switches on these):
#   0   ok, pins.nix rewritten  OR  no-op (nothing to do)
#   20  HALT: repodata advertises a release GitHub never published (F3)
#   22  HALT: version map unparseable
#   30  HALT: SLSA provenance format changed (F2)
#   40  HALT: signing key changed, evidence incomplete -- fully manual (F1)
#   41  HALT: vendored Sigstore trusted root does not match its pin
#   42  PROPOSED: signing key rotation -- 4 independent channels agree AND the
#       old key signed the new one; anchor files rewritten, kind="key-rotation"
#       emitted. The workflow opens a needs-human-approval PR and does NOT
#       auto-merge; 40-review.sh R1 keeps it un-mergeable until a human confirms
#       a further channel and signs the KEY-PROVENANCE.md row.
#   11/12/13  a verification layer failed
#   2   usage / wrong directory
#
# On a HALT it writes ./HALT.txt and touches nothing. On 42 it rewrites
# verify/fingerprint.env + pins.nix + KEY-PROVENANCE.md and emits JSON.
{
  writeShellApplication,
  curl,
  gnupg,
  gh,
  jq,
  libxml2,
  rpm,
  gzip,
  zstd,
  gnused,
  gawk,
  findutils,
  coreutils,
  git,
  cacert,
  slsa-verifier,
  nix,
  nixfmt,
}:
writeShellApplication {
  name = "trivalent-update";
  # SC2001: `sed -s'` to indent piped output. SC2016: literal backticks in a
  # markdown table row printf.
  excludeShellChecks = [
    "SC2001"
    "SC2016"
  ];
  runtimeInputs = [
    curl
    gnupg
    gh
    jq
    libxml2
    rpm
    gzip
    zstd
    gnused
    gawk
    findutils
    coreutils
    git
    cacert
    slsa-verifier
    nix
    nixfmt
  ];
  text = ''
    set -euo pipefail
    NIXFLAGS=(--extra-experimental-features "nix-command flakes")
    ARCH="x86_64"

    halt() { echo "$*" >./HALT.txt; echo "HALT: $*" >&2; }
    say() { echo "[update] $*" >&2; }

    [ -f flake.nix ] && [ -f pins.nix ] && [ -x verify/20-version-map.sh ] ||
      { echo "run me from a trivalent-nix checkout" >&2; exit 2; }
    rm -f ./HALT.txt
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export TRIVALENT_VERIFY_INSHELL=1 # verify/ scripts: skip their nix-shell re-exec

    # ---- read anchors + pins from the WORKING TREE (not a build snapshot) -----
    FPR="$(sed -n 's/^SECUREBLUE_FPR=//p' verify/fingerprint.env)"
    GPG_SHA256="$(sed -n 's/^SECUREBLUE_GPG_SHA256=//p' verify/fingerprint.env)"
    PJ="$(nix "''${NIXFLAGS[@]}" eval --file ./pins.nix --json)"
    KEY_URL="$(jq -r .keyUrl <<<"$PJ")"
    KEY_HASH_PINNED="$(jq -r .keyHash <<<"$PJ")"
    TR_SHA256_PINNED="$(jq -r .sigstoreTrustedRootSha256 <<<"$PJ")"
    PINNED_VR="$(jq -r ".''${ARCH}.versionRelease" <<<"$PJ")"
    sri() { nix "''${NIXFLAGS[@]}" hash convert --hash-algo sha256 --to sri "$1"; }

    envv() { sed -n "s/.*$1:=\\([^}\"]*\\).*/\\1/p" verify/fingerprint.env; }
    GH_SB="$(envv SECUREBLUE_GH_REPO)"
    GH_SB_PATH="$(envv SECUREBLUE_GPG_COMMITTED_PATH)"
    GH_TV="$(envv TRIVALENT_GH_REPO)"

    # ---- F1 preflight: never auto-ADOPT a new key. If one appears, gather
    #      independent evidence and PROPOSE a needs-human PR (exit 42); if the
    #      evidence is incomplete, full HALT (exit 40).
    say "preflight: signing key + Sigstore trusted root"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    curl -fsSL --proto '=https' "$KEY_URL" -o "$tmp/key.gpg"
    key_sha="$(sha256sum "$tmp/key.gpg" | cut -d' ' -f1)"
    export GNUPGHOME="$tmp/gnupg"
    mkdir -p "$GNUPGHOME"
    chmod 700 "$GNUPGHOME"
    gpg --quiet --import "$tmp/key.gpg" 2>/dev/null || true
    key_fpr="$(gpg --list-keys --with-colons 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"

    if [ "$(sri "$key_sha")" != "$KEY_HASH_PINNED" ] || [ "$key_sha" != "$GPG_SHA256" ] || [ "$key_fpr" != "$FPR" ]; then
      say "served signing key differs from the pin -- gathering rotation evidence"
      reasons=()
      # channel B: the key committed in secureblue/secureblue (different host+path)
      gh api "repos/$GH_SB/contents/$GH_SB_PATH" -H "Accept: application/vnd.github.raw" \
        > "$tmp/B.gpg" 2>/dev/null || reasons+=("channel B (github $GH_SB) fetch failed")
      b_sha="$(sha256sum "$tmp/B.gpg" 2>/dev/null | cut -d' ' -f1)"
      [ -n "$b_sha" ] && [ "$b_sha" = "$key_sha" ] || reasons+=("channel A (repo.secureblue.dev) and B (github) disagree")
      # channel C: %_gpg_name in the Trivalent build workflow
      c_fpr="$(gh api "repos/$GH_TV/contents/.github/workflows/build.yml" -H "Accept: application/vnd.github.raw" 2>/dev/null \
              | grep -oiE '_gpg_name[[:space:]]+[0-9a-f]{40}' | grep -oiE '[0-9a-f]{40}' | tr 'a-f' 'A-F' | head -1)"
      [ "$c_fpr" = "$key_fpr" ] || reasons+=("build.yml %_gpg_name ($c_fpr) != served key fpr ($key_fpr)")
      # channel D: fetch the OLD pinned key from an independent keyserver and
      # check it CERTIFIED the new key (a self-signed rotation -- an
      # endpoint-only attacker cannot produce this without the old private key)
      old16="$(printf '%s' "$FPR" | tail -c 16 | tr 'A-F' 'a-f')"
      gpg --batch --keyserver hkps://keyserver.ubuntu.com --keyserver-options timeout=20 \
        --recv-keys "$FPR" 2>/dev/null || reasons+=("could not fetch the old key $FPR from keyserver.ubuntu.com")
      if gpg --check-sigs --with-colons "$key_fpr" 2>/dev/null \
         | awk -F: -v k="$old16" '$1=="sig" && $2=="!" && tolower($5) ~ k {ok=1} END{exit !ok}'; then
        say "channel D: the pinned key $FPR has a verified signature over $key_fpr"
      else
        reasons+=("the pinned key $FPR has NOT verifiably signed the new key $key_fpr (no self-certified rotation)")
      fi

      if [ "''${#reasons[@]}" -eq 0 ]; then
        say "all machine checks pass -- PROPOSING a needs-human key-rotation PR (never auto-merged)"
        new_sri="$(sri "$key_sha")"
        sed -i "s|^SECUREBLUE_FPR=.*|SECUREBLUE_FPR=$key_fpr|; s|^SECUREBLUE_GPG_SHA256=.*|SECUREBLUE_GPG_SHA256=$key_sha|" verify/fingerprint.env
        sed -i "s|keyHash = \"[^\"]*\"|keyHash = \"$new_sri\"|" pins.nix
        nixfmt pins.nix
        printf '| %s | `%s` | `%s` | repo.secureblue.dev OK | github %s OK | build.yml OK + old key signed new (keyserver.ubuntu.com) | PROPOSED-BY-BOT -- confirm a further independent channel (secureblue announcement / Discord / release notes) then replace this with your name |\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$key_fpr" "$key_sha" "$GH_SB" >> KEY-PROVENANCE.md
        jq -cn --arg old "$FPR" --arg new "$key_fpr" \
          --arg msg "signing key: $(printf '%.8s' "$FPR") -> $(printf '%.8s' "$key_fpr") (PROPOSED -- needs human)" \
          --arg body "Auto-detected key rotation. Machine checks that ALL passed: channel A (repo.secureblue.dev) == B (github $GH_SB), build.yml %_gpg_name == new fpr, and the pinned key $FPR carries a *verified* certification over $key_fpr (old key fetched from keyserver.ubuntu.com). NOT auto-merged. A human must (1) confirm the rotation via a channel not above -- secureblue's announcement / Discord / release notes -- and (2) replace 'PROPOSED-BY-BOT' in the new KEY-PROVENANCE.md row with their name. \`ci\` (verify/40-review.sh R1) blocks merge until then." \
          '[{attrPath:"trivalent-signing-key", kind:"key-rotation", oldVersion:$old, newVersion:$new,
             files:["verify/fingerprint.env","pins.nix","KEY-PROVENANCE.md"],
             commitMessage:$msg, commitBody:$body}]'
        say "key rotation PROPOSED: $FPR -> $key_fpr"
        exit 42
      fi

      halt "F1 signing key changed and cannot be auto-proposed: $(IFS=';'; echo "''${reasons[*]}"). Fully manual -- MAINTENANCE.md 'Key rotation'."
      exit 40
    fi

    tr_sha="$(sha256sum verify/sigstore-trusted-root.json | cut -d' ' -f1)"
    if [ "$tr_sha" != "$TR_SHA256_PINNED" ]; then
      halt "verify/sigstore-trusted-root.json sha256 $tr_sha != pinned $TR_SHA256_PINNED -- MAINTENANCE.md 'Sigstore trusted-root rotation'."
      exit 41
    fi
    say "preflight OK (key $FPR)"

    # ---- discover ----------------------------------------------------------
    say "discover: repodata vs GitHub"
    set +e
    vm_out="$(VMAP_RETRIES=0 ./verify/20-version-map.sh "$ARCH" 2>&1)"
    vm_rc=$?
    set -e
    sed 's/^/  20> /' <<<"$vm_out" >&2
    case "$vm_rc" in
      0) ;;
      10 | 21)
        say "repodata behind GitHub (benign lag) -- nothing to do this run"
        exit 0
        ;;
      20)
        halt "F3: repodata advertises a release GitHub never published for $ARCH."
        exit 20
        ;;
      22)
        halt "version map unparseable (see 20> output above)."
        exit 22
        ;;
      *)
        halt "20-version-map.sh exited $vm_rc unexpectedly."
        exit "$vm_rc"
        ;;
    esac
    CAND="$(sed -n 's/^VERSION=//p' <<<"$vm_out" | tail -n1)"
    [ -n "$CAND" ] || {
      halt "20-version-map.sh exited 0 without a VERSION= line."
      exit 22
    }
    if [ "$CAND" = "$PINNED_VR" ]; then
      say "no-op: pinned == latest ($CAND)"
      exit 0
    fi
    say "candidate: $PINNED_VR -> $CAND"

    # ---- verify (live: 3 layers + slsa-verifier Sigstore/Rekor) -----------
    say "verify: 3 layers incl. live slsa-verifier"
    set +e
    v_out="$(./verify/10-verify-supply-chain.sh "$CAND" "$ARCH" 2>&1)"
    v_rc=$?
    set -e
    sed 's/^/  10> /' <<<"$v_out" >&2
    if [ "$v_rc" -ne 0 ]; then
      case "$v_rc" in
        30) halt "F2: SLSA provenance format changed for $CAND -- update lib/verify.nix + lib/anchors.nix." ;;
        31) halt "SLSA provenance missing for $CAND." ;;
        40) halt "F1 key mismatch during verify of $CAND." ;;
        *) halt "supply-chain verification of $CAND failed (10-verify exit $v_rc)." ;;
      esac
      exit "$v_rc"
    fi

    # 10-verify wrote verify/logs/$CAND/ and printed  key = "value";  lines
    # between the two "--- ... ---" markers.
    blk="$(sed -n '/--- paste into pins.nix/,/--- keyHash/p' <<<"$v_out" | grep -E '^[[:space:]]+[a-zA-Z][a-zA-Z0-9]* = ".*";$')"
    [ -n "$blk" ] || {
      halt "could not parse the pins block from 10-verify output."
      exit 12
    }
    fld() { sed -n "s/^[[:space:]]*$1 = \"\\(.*\\)\";\$/\\1/p" <<<"$blk"; }

    # ---- rewrite pins.nix (regen the x86_64 block, keep sentinels/comments) -
    say "rewriting pins.nix"
    {
      printf '  x86_64 = {\n'
      printf '    versionRelease = "%s"; # trivalent-x86_64-vr\n' "$CAND"
      printf '    version = "%s"; # trivalent-x86_64-ver\n\n' "$(fld version)"
      printf '    rpmUrl = "%s"; # trivalent-x86_64-url\n' "$(fld rpmUrl)"
      printf '    rpmHash = "%s"; # trivalent-x86_64-hash\n' "$(fld rpmHash)"
      printf '    rpmSha256 = "%s"; # trivalent-x86_64-sha256\n\n' "$(fld rpmSha256)"
      printf '    # signed repo metadata (moves every publish)\n'
      printf '    repomdUrl = "%s";\n' "$(fld repomdUrl)"
      printf '    repomdHash = "%s";\n' "$(fld repomdHash)"
      printf '    repomdAscUrl = "%s";\n' "$(fld repomdAscUrl)"
      printf '    repomdAscHash = "%s";\n' "$(fld repomdAscHash)"
      printf '    primaryUrl = "%s";\n' "$(fld primaryUrl)"
      printf '    primaryHash = "%s";\n\n' "$(fld primaryHash)"
      printf '    # SLSA provenance (immutable per release tag)\n'
      printf '    intotoUrl = "%s";\n' "$(fld intotoUrl)"
      printf '    intotoHash = "%s";\n\n' "$(fld intotoHash)"
      printf '    # verified: %s  layers 1+2+3 = 0/0/0  key %s\n' "$(date -u +%Y-%m-%d)" "$FPR"
      printf '  };\n'
    } >"$tmp/block"

    awk -v bf="$tmp/block" '
      $0 == "  x86_64 = {" { while ((getline l < bf) > 0) print l; close(bf); skip=1; next }
      skip && $0 == "  };"  { skip=0; next }
      !skip
    ' pins.nix >"$tmp/pins.new"
    mv "$tmp/pins.new" pins.nix
    nixfmt pins.nix

    if git diff --quiet -- pins.nix; then
      say "pins.nix unchanged after rewrite -- no-op"
      git checkout -- verify/logs 2>/dev/null || true
      exit 0
    fi

    # ---- re-verify offline in the build graph ----------------------------
    say "re-verify offline: nix build .#supply-chain"
    if ! nix "''${NIXFLAGS[@]}" build .#supply-chain --no-link -L; then
      git checkout -- pins.nix
      halt "nix build .#supply-chain failed against the freshly written pins -- reverted."
      exit 12
    fi
    say "offline re-verify PASS"

    # ---- emit the passthru.updateScript JSON ----------------------------
    mapfile -t logfiles < <(find "verify/logs/$CAND" -maxdepth 1 -type f)
    jq -cn \
      --arg old "$PINNED_VR" --arg new "$CAND" \
      --argjson files "$(printf '%s\n' "pins.nix" "''${logfiles[@]}" | jq -R . | jq -s .)" \
      --arg msg "trivalent: $PINNED_VR -> $CAND" \
      --arg body "layers 1+2+3 PASS (live slsa-verifier + offline cosign) -- key $FPR" \
      '[{attrPath:"trivalent", oldVersion:$old, newVersion:$new, files:$files,
         commitMessage:$msg, commitBody:$body}]'
    say "done: $PINNED_VR -> $CAND"
  '';
}
