# Verified upstream pins. Every hash here was produced by
# verify/10-verify-supply-chain.sh for the given <version-release> (it does the
# full check, incl. the cosign Sigstore chain over the release provenance, and prints a
# ready-to-paste block). lib/verify.nix then RE-checks all of it offline as part
# of `nix build` -- layers 1+2 fully, layer 3 by binding the provenance CONTENT
# (subject hash + builder/source identity) to this exact RPM. The Sigstore
# signature chain is ALSO re-verified there, offline, by cosign against the
# vendored trusted root (verify/lib/provenance.sh handles both provenance formats).
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
    versionRelease = "158.0.8127.88-448874"; # trivalent-x86_64-vr
    version = "158.0.8127.88"; # trivalent-x86_64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-158.0.8127.88-448874.x86_64.rpm"; # trivalent-x86_64-url
    rpmHash = "sha256-B3yCnE1PM9kiYzm65bpGA3cMJLUnq4orYbXhqKHhxUI="; # trivalent-x86_64-hash
    rpmSha256 = "077c829c4d4f33d9226339bae5ba4603770c24b527ab8a2b61b5e1a8a1e1c542"; # trivalent-x86_64-sha256

    # signed repo metadata (repomd.xml{,.asc}, primary.xml.zst) is a vendored
    # snapshot in verify/repodata/ -- GPG-checked in lib/verify.nix layer 2, not
    # pinned here, because upstream rewrites repomd.xml on every publish.

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/158.0.8127.88-448874-x86_64/provenance.intoto.json";
    intotoHash = "sha256-1tK2EWAPzH4vkmt2QsTZHRTCAepR/wXP+XPiLwmwSIU=";

    # verified: 2026-11-26  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };

  aarch64 = {
    versionRelease = "158.0.8127.88-448874"; # trivalent-aarch64-vr
    version = "158.0.8127.88"; # trivalent-aarch64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-158.0.8127.88-448874.aarch64.rpm"; # trivalent-aarch64-url
    rpmHash = "sha256-knCbLvaRXDmYFn35kiBHMGMmAu9/P0yFskWs+R4im/w="; # trivalent-aarch64-hash
    rpmSha256 = "92709b2ef6915c3998167df992204730632602ef7f3f4c85b245acf91e229bfc"; # trivalent-aarch64-sha256

    # signed repo metadata (repomd.xml{,.asc}, primary.xml.zst) is a vendored
    # snapshot in verify/repodata/ -- GPG-checked in lib/verify.nix layer 2, not
    # pinned here, because upstream rewrites repomd.xml on every publish.

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/158.0.8127.88-448874-aarch64/provenance.intoto.json";
    intotoHash = "sha256-crdwwrUZiDbCI8QjapyZrm9+Mumd6TUjozR3b/yL3bI=";

    # verified: 2026-11-26  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };
}
