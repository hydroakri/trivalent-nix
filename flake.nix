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
          anchors = import ./lib/anchors.nix { inherit (nixpkgs) lib; };
          # pure, offline, in the build graph: layers 1+2+3
          verified = pkgs.callPackage ./lib/verify.nix { inherit anchors pins arch; };
        in
        {
          supply-chain = verified;
          # opt-in F5 VM check -- `nix build .#sandbox-vm-test` (needs /dev/kvm);
          # deliberately NOT in `checks` so `nix flake check` stays VM-free.
          sandbox-vm-test = import ./lib/vm-test.nix { inherit pkgs self; };
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

      checks = forAllSystems (system: {
        formatting = treefmtEval.${system}.config.build.check self;
        # builds the package -> runs its installCheckPhase (interpreter +
        # DT_NEEDED resolution + launcher-structure guard). This is the
        # nixpkgs-drift gate: `nix flake check` goes red before a broken
        # browser can be deployed.
        trivalent = self.packages.${system}.trivalent;
        # pure offline re-verification of the pinned RPM (layers 1+2+3) --
        # `nix flake check` fails if any layer fails.
        supply-chain = self.packages.${system}.supply-chain;
        # cheap eval-only gate: the pinned SRI is well-formed and the log exists
        pin-log-present = (pkgsFor system).runCommand "pin-log-present" { } ''
          test -f ${./verify/logs + "/${pins.x86_64.versionRelease}"}/summary.txt
          grep -q "RESULT: PASS" ${./verify/logs + "/${pins.x86_64.versionRelease}"}/summary.txt
          touch $out
        '';
      });
    };
}
