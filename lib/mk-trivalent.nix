# Trivalent, repackaged from the secureblue RPM.
#
# Technique borrowed from quixaq/trivalent-nix (rpm2cpio unpack + FHS wrap);
# trust baseline is NOT borrowed -- the RPM's sha256 here is one that
# verify/10-verify-supply-chain.sh returned RESULT: PASS for (all three of rpm
# body signature, signed repodata, SLSA provenance), and its log lives at
# verify/logs/<version-release>/ and is copied into $out below.
#
# ---------------------------------------------------------------------------
# F4 (glibc symbol compatibility) -- STATUS: measured on omen15, see
#   ../F4-F5-RESULTS.md. The Trivalent binary references GLIBC_2.43
#   (readelf -V); nixpkgs-unstable is glibc 2.42. `glibcStrategy = "nixpkgs"`
#   (Branch A, autoPatchelfHook) is retained and runnable but FAILS at load
#   time with a 2.43 version error. `glibcStrategy = "fedora-rpm"` (Branch B)
#   is the default: patch the interpreter + rpath onto a Fedora 44 glibc tree.
#
# F5 (sandbox call-path parity under the FHS wrapper) -- STATUS: measured on
#   omen15, see ../F4-F5-RESULTS.md. The RPM ships NO setuid chrome-sandbox
#   helper (find: none), so there is no setuid path for buildFHSEnv to break.
#   The vendor launcher trivalent.sh runs the browser inside its own
#   `bwrap --cap-drop ALL` jail; Chromium then brings up its unprivileged
#   user-namespace + seccomp-bpf sandbox for renderers. We run the UNMODIFIED
#   trivalent.sh as the FHS runScript so that outer jail is preserved rather
#   than dropped (quixaq execs the raw binary and loses it). verify/30-sandbox-
#   selfcheck.sh is the runtime gate that this did not silently downgrade.
# ---------------------------------------------------------------------------
{
  lib,
  stdenv,
  buildFHSEnv,
  callPackage,
  fetchurl,
  rpm,
  cpio,
  patchelf,
  autoPatchelfHook,
  # runtime libs the ELF needs (patchelf --print-needed):
  glib,
  glibc,
  nss,
  nspr,
  atk,
  at-spi2-core,
  dbus,
  cups,
  expat,
  libxcb,
  libx11,
  libxext,
  libxcomposite,
  libxdamage,
  libxfixes,
  libxrandr,
  libxkbcommon,
  alsa-lib,
  mesa,
  libgbm ? mesa,
  libffi,
  cairo,
  pango,
  systemd,
  pipewire,
  gcc-unwrapped,
  # wrapper env:
  bubblewrap,
  coreutils,
  bashInteractive,

  arch ? (lib.head (lib.splitString "-" stdenv.hostPlatform.system)),
  versionInfo, # { versionRelease; version; url; hash; verifyLogDir ? null; }
  glibcStrategy ? "fedora-rpm", # "fedora-rpm" (F4 branch B, default) | "nixpkgs" (branch A)
}:
let
  inherit (versionInfo)
    versionRelease
    version
    url
    hash
    ;
  verifyLogDir = versionInfo.verifyLogDir or null;

  runtimeLibs = [
    glib
    nss
    nspr
    atk
    at-spi2-core
    dbus
    cups
    expat
    libxcb
    libx11
    libxext
    libxcomposite
    libxdamage
    libxfixes
    libxrandr
    libxkbcommon
    alsa-lib
    mesa
    libgbm
    libffi
    cairo
    pango
    systemd
    pipewire
    gcc-unwrapped.lib
  ];

  fedoraGlibc =
    if glibcStrategy == "fedora-rpm" then callPackage ./mk-glibc-rpm.nix { inherit arch; } else null;

  src = fetchurl { inherit url hash; };

  trivalentUnwrapped = stdenv.mkDerivation {
    pname = "trivalent-unwrapped";
    inherit version src;

    nativeBuildInputs = [
      rpm
      cpio
      patchelf
    ]
    ++ lib.optional (glibcStrategy == "nixpkgs") autoPatchelfHook;

    # autoPatchelfHook (branch A only) consumes these; harmless for branch B.
    buildInputs = runtimeLibs ++ lib.optional (glibcStrategy == "nixpkgs") glibc;

    unpackPhase = ''
      runHook preUnpack
      rpm2cpio "$src" | cpio -idm --quiet
      runHook postUnpack
    '';

    dontConfigure = true;
    dontBuild = true;

    # Keep the vendor artifacts as close to the (verified) RPM as possible:
    # no shebang rewrite of trivalent.sh, no strip of the browser binary, no
    # lib64->lib shuffle. buildFHSEnv provides /usr/bin/bash so #!/usr/bin/bash
    # stays valid. (F5: fewer edits to the security-sensitive launcher.)
    dontPatchShebangs = true;
    dontStrip = true;
    dontMoveLib64 = true;
    # Branch B does its own interpreter/rpath patching; keep the generic ELF
    # hook off so it doesn't fight it. Branch A lets autoPatchelfHook run.
    dontAutoPatchelf = glibcStrategy != "nixpkgs";
    dontPatchELF = glibcStrategy != "nixpkgs";

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -a usr/. "$out/"
      [ -d etc ] && cp -a etc "$out/etc" || true
      chmod -R u+w "$out"   # RPM ships read-only dirs; we still need to write into them

      binroot="$(dirname "$(find "$out" -name trivalent.sh -type f | head -n1)")"
      [ -n "$binroot" ] && [ -f "$binroot/trivalent" ] || { echo "layout changed: no trivalent.sh / trivalent"; exit 1; }
      echo "binroot=$binroot"

      # $out/bin/trivalent is a relative symlink into ../../usr/lib64/... from the
      # RPM; repoint it at the real launcher inside $out.
      mkdir -p "$out/bin"
      ln -sf "$binroot/trivalent.sh" "$out/bin/trivalent"

      ${lib.optionalString (glibcStrategy == "fedora-rpm") ''
        interp="${fedoraGlibc}/usr/lib64/ld-linux-x86-64.so.2"
        [ "${arch}" = "aarch64" ] && interp="${fedoraGlibc}/usr/lib/ld-linux-aarch64.so.1"
        newrpath="${fedoraGlibc}/usr/lib64:${lib.makeLibraryPath runtimeLibs}"
        for elf in "$binroot/trivalent" "$binroot/chrome_crashpad_handler"; do
          [ -f "$elf" ] || continue
          patchelf --set-interpreter "$interp" "$elf" || true
          old="$(patchelf --print-rpath "$elf" 2>/dev/null || true)"
          patchelf --set-rpath "$newrpath''${old:+:$old}" "$elf"
        done
      ''}

      # supply-chain verification log travels with the package (acceptance req 1)
      logdir="$out/share/trivalent/supply-chain-logs"
      mkdir -p "$logdir"
      ${lib.optionalString (verifyLogDir != null) ''
        cp -r --no-preserve=mode,ownership ${verifyLogDir}/. "$logdir/"
      ''}
      printf '%s\n' \
        "version-release : ${versionRelease}" \
        "rpm url         : ${url}" \
        "rpm sri         : ${hash}" \
        "glibc strategy  : ${glibcStrategy}" > "$logdir/PIN.txt"
      chmod -R u+w "$out/share/trivalent"

      runHook postInstall
    '';

    # Fail the BUILD loudly on nixpkgs drift instead of shipping a broken
    # browser: every DT_NEEDED must resolve inside the RPATH we set, the
    # interpreter must exist, and the vendor launcher must still have the
    # structure F5 relies on. A renamed/soname-bumped runtime lib, a glibc
    # that outgrows the Fedora one, or an upstream launcher rewrite all trip
    # this -- and `nix flake check` runs it (see checks.trivalent).
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      bin="$(find "$out" -path '*/trivalent/trivalent' -type f | head -n1)"
      [ -n "$bin" ] || { echo "drift: no trivalent binary in \$out"; exit 1; }

      interp="$(patchelf --print-interpreter "$bin")"
      echo "interpreter: $interp"
      [ -e "$interp" ] || { echo "drift: interpreter '$interp' does not exist"; exit 1; }

      rpath="$(patchelf --print-rpath "$bin")"
      echo "rpath: $rpath"
      IFS=: read -ra dirs <<< "$rpath"
      miss=0
      while read -r so; do
        case "$so" in ld-linux*|"") continue ;; esac
        found=
        for d in "''${dirs[@]}"; do [ -e "$d/$so" ] && { found=1; break; }; done
        if [ -z "$found" ]; then echo "drift: DT_NEEDED '$so' not resolvable in rpath"; miss=1; fi
      done < <(patchelf --print-needed "$bin")
      [ "$miss" -eq 0 ] || { echo "drift: unresolved shared libraries (nixpkgs rename/soname bump?)"; exit 1; }

      sh="$(find "$out" -name trivalent.sh -type f | head -n1)"
      grep -q 'exec bwrap' "$sh" || { echo "drift: vendor trivalent.sh no longer 'exec bwrap' -- re-check F5"; exit 1; }
      grep -q 'readlink -f "\?''${0}' "$sh" || echo "note: trivalent.sh \$0-resolution idiom changed (non-fatal)"
      echo "installCheck OK: interpreter + all DT_NEEDED resolve, launcher structure intact"
      runHook postInstallCheck
    '';

    passthru = { inherit fedoraGlibc; };
  };
in
buildFHSEnv {
  pname = "trivalent";
  inherit version;

  # Run the vendor launcher UNMODIFIED (see F5 note above).
  runScript = "${trivalentUnwrapped}/bin/trivalent";

  targetPkgs =
    pkgs:
    (with pkgs; [
      bubblewrap # vendor trivalent.sh: `exec bwrap ...`
      coreutils # id, uname, readlink, mkdir, touch, cat
      bashInteractive # #!/usr/bin/bash + `source` of conf.d
    ])
    ++ runtimeLibs;

  extraInstallCommands = ''
    mkdir -p "$out/share/applications" "$out/share/icons"
    cp -a ${trivalentUnwrapped}/share/applications/. "$out/share/applications/" || true
    cp -a ${trivalentUnwrapped}/share/icons/. "$out/share/icons/" || true
    cp -a ${trivalentUnwrapped}/share/trivalent "$out/share/trivalent" || true
    substituteInPlace "$out/share/applications/trivalent.desktop" \
      --replace-quiet "/usr/bin/trivalent" "$out/bin/trivalent" || true
  '';

  passthru = {
    unwrapped = trivalentUnwrapped;
    inherit (trivalentUnwrapped.passthru) fedoraGlibc;
    inherit versionRelease glibcStrategy;
  };

  meta = {
    description = "secureblue Trivalent (hardened Chromium), repackaged from the signed RPM with 3-layer supply-chain verification";
    homepage = "https://github.com/secureblue/Trivalent";
    license = lib.licenses.bsd3; # Chromium
    mainProgram = "trivalent";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
