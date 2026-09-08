{
  description = "Trivalent (secureblue hardened Chromium), repackaged from the signed RPM with three-layer supply-chain verification";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      treefmt-nix,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      pins = import ./pins.nix;

      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule (pkgsFor system) {
          projectRootFile = "flake.nix";
          programs = {
            nixfmt.enable = true;
            statix.enable = true;
            deadnix.enable = true;
            shfmt.enable = true;
          };
          settings.formatter.shfmt.excludes = [ "verify/logs/**" ];
        }
      );
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          arch = nixpkgs.lib.head (nixpkgs.lib.splitString "-" system);
          pin = pins.${arch};
          anchors = import ./lib/anchors.nix { inherit (nixpkgs) lib; };
          # pure, offline, in the build graph: layers 1+2+3
          verified = pkgs.callPackage ./lib/verify.nix { inherit anchors pins arch; };
        in
        {
          supply-chain = verified;
          # opt-in F5 VM check -- `nix build .#sandbox-vm-test` (needs /dev/kvm);
          # deliberately NOT in `checks` so `nix flake check` stays VM-free.
          sandbox-vm-test = import ./lib/vm-test.nix { inherit pkgs self; };
          # shared canary for the behavioural preload checks (verify/30 + more)
          preload-sentinel = pkgs.callPackage ./lib/preload-sentinel.nix { };
          trivalent = pkgs.callPackage ./lib/mk-trivalent.nix {
            inherit arch;
            versionInfo = pin // {
              inherit verified;
              verifyLogDir = ./verify/logs + "/${pin.versionRelease}";
            };
            # F4: default "fedora-rpm" (branch B). "nixpkgs" (branch A) is
            # retained but load-fails on GLIBC_2.43 -- see F4-F5-RESULTS.md.
            glibcStrategy = "fedora-rpm";
          };
          default = self.packages.${system}.trivalent;
        }
      );

      # options.programs.trivalent.{enable, package, apparmor.*}
      # apparmor.enable adds a store-path-generated profile that stands in for
      # the trivalent-selinux policy NixOS cannot run (complain by default).
      nixosModules.default = import ./modules/nixos.nix { inherit self; };

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # Tools the verify/ scripts need, so they can run without the
          # self-bootstrap `nix shell` re-exec.
          default = pkgs.mkShellNoCC {
            packages = with pkgs; [
              curl
              gnupg
              gh
              jq
              libxml2 # xmllint -- repodata parsing in verify/10 + verify/20
              rpm
              slsa-verifier
              cpio
              gzip
              zstd
              cacert
              busybox # fixture HTTP server for verify/99-negative-tests.sh
            ];
          };
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # `nix run .#sandbox-selfcheck -- https://example.org`
          sandbox-selfcheck = {
            type = "app";
            program = "${self}/verify/30-sandbox-selfcheck.sh";
          };
          # unattended updater: `nix run .#update` from a checkout. Reads
          # pins.nix / fingerprint.env from the working tree at run time.
          update = {
            type = "app";
            program = "${pkgs.callPackage ./lib/update.nix { }}/bin/trivalent-update";
          };
        }
      );

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          arch = nixpkgs.lib.head (nixpkgs.lib.splitString "-" system);
          triv = self.packages.${system}.trivalent;
          # stands in for `bwrap`: records the argv + the LD_* it was handed,
          # then exits WITHOUT exec'ing. trivalent.sh line 24 hard-resets PATH
          # readonly, so a shim earlier on $PATH is unreachable -- it has to be
          # spliced in by name (the launcher-scrub check does that).
          scrubShim = pkgs.writeShellScript "trivalent-scrub-shim" ''
            {
              printf 'ARGV<<%s>>\n' "$*"
              for v in LD_PRELOAD LD_AUDIT LD_PROFILE LD_LIBRARY_PATH; do
                if [ -n "''${!v+set}" ]; then
                  printf '%s=[%s]\n' "$v" "''${!v}"
                else
                  printf '%s=<UNSET>\n' "$v"
                fi
              done
            } > "$SCRUB_CAPTURE"
            exit 0
          '';
        in
        {
          formatting = treefmtEval.${system}.config.build.check self;
          # builds the package -> runs its installCheckPhase (interpreter +
          # DT_NEEDED resolution + launcher-structure guard). This is the
          # nixpkgs-drift gate: `nix flake check` goes red before a broken
          # browser can be deployed.
          trivalent = triv;
          # pure offline re-verification of the pinned RPM (layers 1+2+3) --
          # `nix flake check` fails if any layer fails.
          supply-chain = self.packages.${system}.supply-chain;
          # cheap eval-only gate: the pinned SRI is well-formed and the log exists
          pin-log-present = pkgs.runCommand "pin-log-present" { } ''
            test -f ${./verify/logs + "/${pins.${arch}.versionRelease}"}/summary.txt
            grep -q "RESULT: PASS" ${./verify/logs + "/${pins.${arch}.versionRelease}"}/summary.txt
            touch $out
          '';

          # Behavioural gate for the LD_PRELOAD / /etc/ld.so.preload scrub
          # (see lib/mk-trivalent.nix F5 note). Runs the REAL, unmodified
          # trivalent.sh with `bwrap` replaced by a shim, under a hostile
          # `env -i LD_PRELOAD=... LD_AUDIT=... LD_PROFILE=...`, and asserts
          # every LD_* is neutralised by the time the browser would exec --
          # plus that our own fhsLaunch `env -u` wrapper and the
          # `--ro-bind-try /dev/null /etc/ld.so.preload` mask are still wired.
          # No real bwrap / userns / network / KVM.
          launcher-scrub =
            let
              unwrapped = triv.passthru.unwrapped;
            in
            pkgs.runCommand "trivalent-launcher-scrub"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.bash
                  pkgs.gnugrep
                  pkgs.gnused
                  pkgs.findutils
                ];
              }
              ''
                set -euo pipefail

                sh="$(find ${unwrapped}/lib64 -name trivalent.sh -type f | head -n1)"
                [ -n "$sh" ] || { echo "SCRUB-CHECK FAIL: trivalent.sh not found in unwrapped output"; exit 1; }
                work="$TMPDIR/trivalent.sh"
                cp "$sh" "$work"
                chmod +w "$work"

                anchor() { # <ERE> <human name>
                  grep -qE -- "$1" "$work" || {
                    echo "SCRUB-CHECK FAIL: anchor for [$2] not found in trivalent.sh."
                    echo "  Upstream refactored the launcher. Re-audit the LD_* scrub BY HAND,"
                    echo "  then fix this check's sed anchor. Do NOT just delete the check."
                    exit 1
                  }
                }

                # 5 surgical rewrites so the vendor script runs in a build
                # sandbox; every target line is unrelated to LD_* / ld.so.preload.
                anchor '^exec bwrap '                 'exec bwrap line'
                sed -i 's#^exec bwrap #exec "$SCRUB_SHIM" #' "$work"

                anchor 'PATH="/usr/bin:/bin"'         'PATH reset'
                sed -i "s#PATH=\"/usr/bin:/bin\"#PATH=\"$PATH\"#" "$work"

                anchor '/var/tmp/'                    'hardcoded /var/tmp cache'
                sed -i "s#/var/tmp/#$TMPDIR/vtmp/#g" "$work"

                anchor '"\$\(id -u\)" -eq 0'          'refuse-root guard'
                sed -i 's#"\$(id -u)" -eq 0#"$(id -u)" -eq 999999#' "$work"

                anchor 'exec > >\(exec cat\)'         'stdio redirection block'
                sed -i '/exec < \/dev\/null/d;/exec > >(exec cat)/d;/exec 2> >(exec cat >&2)/d' "$work"

                # the lines this check EXISTS to guard must still be present:
                for pat in \
                  'declare -rx LD_LIBRARY_PATH=""' \
                  'declare -rx LD_AUDIT=""' \
                  'declare -rx LD_PROFILE=""' \
                  'declare -rx LD_PRELOAD=""'; do
                  grep -qF -- "$pat" "$work" || {
                    echo "SCRUB-CHECK FAIL: '$pat' is gone from trivalent.sh -- THIS IS THE REGRESSION."
                    echo "  A system LD_PRELOAD (hardened_malloc) could now reach Chromium if"
                    echo "  fhsLaunch's env -u wrapper were also removed. Re-audit."
                    exit 1
                  }
                done

                mkdir -p "$TMPDIR/home" "$TMPDIR/vtmp"
                set +e
                env -i \
                  HOME="$TMPDIR/home" PATH="$PATH" TMPDIR="$TMPDIR" \
                  SCRUB_SHIM=${scrubShim} SCRUB_CAPTURE="$TMPDIR/capture.txt" \
                  LD_PRELOAD=/PROBE/evil.so LD_AUDIT=/PROBE/audit.so \
                  LD_PROFILE=/PROBE/prof.out LD_LIBRARY_PATH=/PROBE/lib \
                  ${pkgs.bash}/bin/bash "$work" --scrub-probe about:blank
                set -e

                cap="$TMPDIR/capture.txt"
                [ -f "$cap" ] || {
                  echo "SCRUB-CHECK FAIL: vendor launcher aborted before its exec line"
                  echo "  (build-sandbox environment problem -- not necessarily a scrub regression)."
                  exit 1
                }
                echo "----- shim capture -----"; cat "$cap"; echo "------------------------"

                grep -qE 'ARGV<<.*-- .*/trivalent' "$cap" || {
                  echo "SCRUB-CHECK FAIL: launcher never reached 'exec bwrap -- .../trivalent'."
                  exit 1
                }

                fail=0
                for v in LD_PRELOAD LD_AUDIT LD_PROFILE LD_LIBRARY_PATH; do
                  if grep -qE "^$v=\[\]$" "$cap" || grep -qE "^$v=<UNSET>$" "$cap"; then
                    :
                  else
                    echo "SCRUB-CHECK FAIL: $v reached the bwrap exec as [$(sed -n "s/^$v=//p" "$cap")]"
                    fail=1
                  fi
                done
                [ "$fail" = 0 ] || { echo "RESULT: trivalent.sh LD_* scrub REGRESSED"; exit 1; }
                echo "OK: trivalent.sh neutralises LD_PRELOAD/LD_AUDIT/LD_PROFILE/LD_LIBRARY_PATH before exec"

                # --- our own wiring (Part A) must still be in place ---
                bw="$(readlink -f ${triv}/bin/trivalent)"
                { grep -q -- '--ro-bind-try' "$bw" && grep -q '/etc/ld.so.preload' "$bw"; } || {
                  echo "WIRING FAIL: outer bwrap no longer masks /etc/ld.so.preload"
                  echo "  (extraBwrapArgs dropped from mk-trivalent.nix, or this buildFHSEnv ignores it)."
                  exit 1
                }
                initsc="$(grep -oE '/nix/store/[a-z0-9]+-trivalent-[0-9.]+-init' "$bw" | head -n1)"
                { [ -n "$initsc" ] && grep -q 'trivalent-fhs-launch' "$initsc"; } || {
                  echo "WIRING FAIL: buildFHSEnv runScript is not our env -u wrapper (fhsLaunch)."
                  exit 1
                }
                launch="$(grep -oE '/nix/store/[a-z0-9]+-trivalent-fhs-launch' "$initsc" | head -n1)"
                { grep -q -- '-u LD_PRELOAD' "$launch" \
                  && grep -q -- '-u LD_AUDIT' "$launch" \
                  && grep -q -- '-u LD_PROFILE' "$launch"; } || {
                  echo "WIRING FAIL: fhsLaunch no longer strips all of LD_PRELOAD/LD_AUDIT/LD_PROFILE."
                  exit 1
                }

                echo "RESULT: launcher scrub + outer masks intact"
                touch "$out"
              '';
        }
      );
    };
}
