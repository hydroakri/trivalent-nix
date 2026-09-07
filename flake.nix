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
      systems = [ "x86_64-linux" ];
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
        in
        {
          trivalent = pkgs.callPackage ./lib/mk-trivalent.nix {
            inherit arch;
            versionInfo = pin // {
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
              python3
              rpm
              slsa-verifier
              cpio
              gzip
              zstd
              cacert
            ];
          };
        }
      );

      apps = forAllSystems (_: {
        # `nix run .#sandbox-selfcheck -- https://example.org`
        sandbox-selfcheck = {
          type = "app";
          program = "${self}/verify/30-sandbox-selfcheck.sh";
        };
      });

      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        # builds the package -> runs its installCheckPhase (interpreter +
        # DT_NEEDED resolution + launcher-structure guard). This is the
        # nixpkgs-drift gate: `nix flake check` goes red before a broken
        # browser can be deployed.
        trivalent = self.packages.${system}.trivalent;
        # cheap eval-only gate: the pinned SRI is well-formed and the log exists
        pin-log-present = (pkgsFor system).runCommand "pin-log-present" { } ''
          test -f ${./verify/logs + "/${pins.x86_64.versionRelease}"}/summary.txt
          grep -q "RESULT: PASS" ${./verify/logs + "/${pins.x86_64.versionRelease}"}/summary.txt
          touch $out
        '';
      });
    };
}
