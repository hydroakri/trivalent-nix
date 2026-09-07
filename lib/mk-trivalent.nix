# Trivalent, repackaged from the secureblue RPM.
#
# Technique borrowed from quixaq/trivalent-nix (rpm2cpio unpack + FHS wrap);
# trust baseline is NOT borrowed -- `src` is lib/verify.nix's output, which
# only contains the RPM after layers 1+2+3 pass offline in the build graph.
# Its log + the shell-flow log ship in $out/share/trivalent/supply-chain-logs/.
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
  # { versionRelease; version; rpmUrl; rpmHash; verified; verifyLogDir ? null; }
  # `verified` is lib/verify.nix's output dir -- its trivalent.rpm is the src, so
  # nothing unverified can enter the build.
  versionInfo,
  glibcStrategy ? "fedora-rpm", # "fedora-rpm" (F4 branch B, default) | "nixpkgs" (branch A)
}:
let
  inherit (versionInfo) versionRelease version;
  url = versionInfo.rpmUrl;
  hash = versionInfo.rpmHash;
  inherit (versionInfo) verified;
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

  # the RPM comes from lib/verify.nix -- it exists there only after layers 1+2+3
  src = "${verified}/trivalent.rpm";

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

      # supply-chain verification logs travel with the package (acceptance req 1)
      logdir="$out/share/trivalent/supply-chain-logs"
      mkdir -p "$logdir"
      cp --no-preserve=mode,ownership ${verified}/supply-chain.log "$logdir/pure-build.log"
      ${lib.optionalString (verifyLogDir != null) ''
        cp -r --no-preserve=mode,ownership ${verifyLogDir}/. "$logdir/"
      ''}
      printf '%s\n' \
        "version-release : ${versionRelease}" \
        "rpm url         : ${url}" \
        "rpm sri         : ${hash}" \
        "verified by     : lib/verify.nix (offline, in the build graph)" \
        "glibc strategy  : ${glibcStrategy}" > "$logdir/PIN.txt"
      chmod -R u+w "$out/share/trivalent"

      runHook postInstall
    '';

    # Fail the BUILD loudly on nixpkgs drift instead of shipping a broken
    # browser. Runs on `nix build` and via `nix flake check` (checks.trivalent).
    # Layers, cheapest first:
    #   1. interpreter exists; every direct DT_NEEDED resolves by name in RPATH
    #      (catches an attr rename that still eval'd, or a soname bump)
    #   2. `ld.so --list` on the patched binary: FULL TRANSITIVE closure -- any
    #      "not found" at any depth fails (a runtime lib whose own deps drifted)
    #   3. actually load+relocate it (`$bin --version`): catches symbol-version
    #      breaks like `GLIBC_2.43 not found` / `undefined symbol` that trace
    #      mode cannot see. A clean env-only failure (no display, minimal /proc
    #      in the sandbox) is tolerated; a linker error is not.
    #   4. the vendor launcher still has the structure F5 depends on
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      fail() { echo "DRIFT: $*"; exit 1; }
      root="$(dirname "$(find "$out" -name trivalent.sh -type f | head -n1)")"
      [ -n "$root" ] && [ -f "$root/trivalent" ] || fail "no trivalent binary in \$out"

      for bin in "$root/trivalent" "$root/chrome_crashpad_handler"; do
        [ -f "$bin" ] || continue
        echo "== $(basename "$bin") =="
        interp="$(patchelf --print-interpreter "$bin")"
        [ -e "$interp" ] || fail "interpreter '$interp' does not exist"
        rpath="$(patchelf --print-rpath "$bin")"
        IFS=: read -ra dirs <<< "$rpath"

        # (1) direct DT_NEEDED resolve by filename
        while read -r so; do
          case "$so" in ld-linux*|"") continue ;; esac
          found=; for d in "''${dirs[@]}"; do [ -e "$d/$so" ] && { found=1; break; }; done
          [ -n "$found" ] || fail "DT_NEEDED '$so' not resolvable in rpath (attr rename / soname bump?)"
        done < <(patchelf --print-needed "$bin")

        # (2) full transitive closure via the (Fedora) ld.so
        list="$("$interp" --list "$bin" 2>&1 || true)"
        if printf '%s\n' "$list" | grep -q 'not found'; then
          printf '%s\n' "$list" | grep 'not found' >&2
          fail "transitive shared-lib closure has unresolved entries"
        fi
        echo "  transitive closure resolves ($(printf '%s\n' "$list" | grep -c '=>') objects)"

        # (3) real load + relocation -- only on the browser binary; the crashpad
        #     handler is an IPC daemon, not a CLI, and --version misbehaves.
        #     The binary is BIND_NOW + full RELRO, so this eagerly resolves EVERY
        #     symbol in the binary AND its entire transitive link closure (not
        #     just the RPATH libs) -- a removed export / soname / glibc-symbol
        #     break anywhere in that graph fails here. LD_BIND_NOW is belt-and-
        #     suspenders in case a future Trivalent build drops the flag.
        #     NOT covered: libraries dlopen()'d at runtime (GL/VA-API drivers,
        #     pipewire/cups modules, libsecret) -- that is verify/30's job.
        if [ "$(basename "$bin")" = trivalent ]; then
          vout="$(timeout 40 env -i HOME="$TMPDIR" PATH=/noexist LD_BIND_NOW=1 \
                    "$bin" --version 2>&1 || true)"
          if printf '%s\n' "$vout" | grep -Eq "version \`GLIBC_[0-9.]+' not found|undefined symbol|error while loading shared|cannot open shared object|relocation error"; then
            printf '%s\n' "$vout" | grep -Ev 'no version information available' >&2
            fail "dynamic loader/relocation error -- glibc or a runtime lib is ABI-incompatible"
          fi
          if printf '%s\n' "$vout" | grep -q "^Trivalent "; then
            echo "  loaded + relocated + ran: $(printf '%s\n' "$vout" | grep '^Trivalent ')"
          else
            echo "  note: no --version banner in the build sandbox, but no linker/reloc error"
          fi
        fi
      done

      sh="$(find "$out" -name trivalent.sh -type f | head -n1)"
      grep -q 'exec bwrap' "$sh" || fail "vendor trivalent.sh no longer 'exec bwrap' -- re-check F5"
      grep -q 'readlink -f "\?''${0}' "$sh" || echo "note: trivalent.sh \$0-resolution idiom changed (non-fatal)"
      echo "installCheck OK: interpreter + transitive closure + load/reloc + launcher structure"
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
