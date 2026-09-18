# Verified upstream pins. Every hash here was produced by
# verify/10-verify-supply-chain.sh for the given <version-release> (it does the
# full check, incl. the live slsa-verifier Sigstore/Rekor chain, and prints a
# ready-to-paste block). lib/verify.nix then RE-checks all of it offline as part
# of `nix build` -- layers 1+2 fully, layer 3 by binding the provenance CONTENT
# (subject hash + builder/source identity) to this exact RPM. The Sigstore
# signature chain itself is not re-verified in the pure build (slsa-verifier
# needs network); trust in it is carried by `intotoHash` being pinned.
#
# This file is rewritten by `nix run .#update` (see lib/update.nix) --
# .github/workflows/update-trivalent.yml runs it daily, gates the result on
# `nix flake check`, and auto-merges on green. F1 events (key / trusted-root
# change) HALT to a GitHub issue instead of touching this file.
# To bump by hand: `nix run .#update` in a checkout, then `./verify/40-review.sh`.
{
  # constant across versions: the signing key, fetched and checked against
  # SECUREBLUE_GPG_SHA256 / the fingerprint in lib/anchors.nix.
  keyUrl = "https://repo.secureblue.dev/secureblue.gpg";
  keyHash = "sha256-QNitJxS7CYcxU2aNnGRzYqzEhneiwN77DH1ldgQf1VU=";

  # sha256 of verify/sigstore-trusted-root.json (vendored). lib/verify.nix
  # refuses to build if the file on disk doesn't match. Rotate ~yearly when
  # Sigstore announces a root change -- procedure in MAINTENANCE.md.
  sigstoreTrustedRootSha256 = "6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66";

  # The signed repo index (repomd.xml{,.asc}, primary.xml.zst) is likewise
  # vendored -- in verify/repodata/ -- and GPG-verified in lib/verify.nix layer
  # 2. It is NOT hash-pinned here: upstream rewrites repomd.xml on every publish,
  # so a pin would break the build on every secureblue release. `nix run .#update`
  # refreshes the snapshot alongside each bump.

  x86_64 = {
    versionRelease = "153.0.8010.52-447428"; # trivalent-x86_64-vr
    version = "153.0.8010.52"; # trivalent-x86_64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-153.0.8010.52-447428.x86_64.rpm"; # trivalent-x86_64-url
    rpmHash = "sha256-jgOKgIxvyuPLL03ElZGgDUz1yhHf1QYVbr52CfGudvE="; # trivalent-x86_64-hash
    rpmSha256 = "8e038a808c6fcae3cb2f4dc49591a00d4cf5ca11dfd506156ebe7609f1ae76f1"; # trivalent-x86_64-sha256

    # signed repo metadata (repomd.xml{,.asc}, primary.xml.zst) is a vendored
    # snapshot in verify/repodata/ -- GPG-checked in lib/verify.nix layer 2, not
    # pinned here, because upstream rewrites repomd.xml on every publish.

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/153.0.8010.52-447428/multiple.intoto.jsonl";
    intotoHash = "sha256-/YRbbaC+EsHQkJc5bAxmtKe5fSRku8894/+v3r+vNaU=";

    # verified: 2026-09-18  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };

  aarch64 = {
    versionRelease = "153.0.8010.52-447430"; # trivalent-aarch64-vr
    version = "153.0.8010.52"; # trivalent-aarch64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-153.0.8010.52-447430.aarch64.rpm"; # trivalent-aarch64-url
    rpmHash = "sha256-tBB/hiVt6QaVW6R4Dr+EWkI4carspFIqeK57JQygsVI="; # trivalent-aarch64-hash
    rpmSha256 = "b4107f86256de906955ba4780ebf845a423871aaeca4522a78ae7b250ca0b152"; # trivalent-aarch64-sha256

    # signed repo metadata (repomd.xml{,.asc}, primary.xml.zst) is a vendored
    # snapshot in verify/repodata/ -- GPG-checked in lib/verify.nix layer 2, not
    # pinned here, because upstream rewrites repomd.xml on every publish.

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/153.0.8010.52-447430/multiple.intoto.jsonl";
    intotoHash = "sha256-bWf9L+FTpXV0L9lyFtM1WJkYtOSbFsELXXzwNCBlO98=";

    # verified: 2026-09-18  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };
}
