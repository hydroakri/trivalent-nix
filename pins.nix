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
    versionRelease = "154.0.8037.92-447681"; # trivalent-x86_64-vr
    version = "154.0.8037.92"; # trivalent-x86_64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-154.0.8037.92-447681.x86_64.rpm"; # trivalent-x86_64-url
    rpmHash = "sha256-F+liqE8zwEvg2lJ/DArDnGhNcH7Oe9eHhRSkykLhGHg="; # trivalent-x86_64-hash
    rpmSha256 = "17e962a84f33c04be0da527f0c0ac39c684d707ece7bd7878514a4ca42e11878"; # trivalent-x86_64-sha256

    # signed repo metadata (repomd.xml{,.asc}, primary.xml.zst) is a vendored
    # snapshot in verify/repodata/ -- GPG-checked in lib/verify.nix layer 2, not
    # pinned here, because upstream rewrites repomd.xml on every publish.

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/154.0.8037.92-447681/multiple.intoto.jsonl";
    intotoHash = "sha256-CEGKYAPZAnbN7uDlmqqJIyJ4tJpeYLy+nUugt3Sd0f4=";

    # verified: 2026-10-01  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };

  aarch64 = {
    versionRelease = "154.0.8037.92-447683"; # trivalent-aarch64-vr
    version = "154.0.8037.92"; # trivalent-aarch64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-154.0.8037.92-447683.aarch64.rpm"; # trivalent-aarch64-url
    rpmHash = "sha256-uxpc+T7UKW5/LI3qHNcFIvISFLQfKKHNnTFkTAo4N8k="; # trivalent-aarch64-hash
    rpmSha256 = "bb1a5cf93ed4296e7f2c8dea1cd70522f21214b41f28a1cd9d31644c0a3837c9"; # trivalent-aarch64-sha256

    # signed repo metadata (repomd.xml{,.asc}, primary.xml.zst) is a vendored
    # snapshot in verify/repodata/ -- GPG-checked in lib/verify.nix layer 2, not
    # pinned here, because upstream rewrites repomd.xml on every publish.

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/154.0.8037.92-447683/multiple.intoto.jsonl";
    intotoHash = "sha256-Hc9N3ynkgxwyWbqCuFmODUIvFPPSWqUEjZtcBiuLhJQ=";

    # verified: 2026-10-01  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };
}
