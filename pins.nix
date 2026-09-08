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

  x86_64 = {
    versionRelease = "152.0.7977.82-447128"; # trivalent-x86_64-vr
    version = "152.0.7977.82"; # trivalent-x86_64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-152.0.7977.82-447128.x86_64.rpm"; # trivalent-x86_64-url
    rpmHash = "sha256-bdMv+VmQ8JYUAE4+Y1I3kiTe2OOfe8Qlsnt1+bE/qn4="; # trivalent-x86_64-hash
    rpmSha256 = "6dd32ff95990f09614004e3e6352379224ded8e39f7bc425b27b75f9b13faa7e"; # trivalent-x86_64-sha256

    # signed repo metadata (moves every publish)
    repomdUrl = "https://repo.secureblue.dev/repodata/repomd.xml";
    repomdHash = "sha256-loI7y7zrMEO/4wlquRvW+HezA6fYzImZ4EEpYY0Iqds=";
    repomdAscUrl = "https://repo.secureblue.dev/repodata/repomd.xml.asc";
    repomdAscHash = "sha256-o5NEm9Y9lcXJvrFiyZExuZEFjDVlnWXKEC/OsOUDw5M=";
    primaryUrl = "https://repo.secureblue.dev/repodata/19c650b7601c2ade6155aef971212e927ce6be6547d9a90949690a8a1d738a37-primary.xml.zst";
    primaryHash = "sha256-GcZQt2AcKt5hVa75cSEuknzmvmVH2akJSWkKih1zijc=";

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/152.0.7977.82-447128/multiple.intoto.jsonl";
    intotoHash = "sha256-aGOZkIpcaxT6uikQGIhUOpTjAPyYCU7ISYQq20SZwe0=";

    # verified: 2026-09-07  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };

  aarch64 = {
    versionRelease = "152.0.7977.82-447136"; # trivalent-aarch64-vr
    version = "152.0.7977.82"; # trivalent-aarch64-ver

    rpmUrl = "https://repo.secureblue.dev/Packages/trivalent-152.0.7977.82-447136.aarch64.rpm"; # trivalent-aarch64-url
    rpmHash = "sha256-Y1LFCU9tyoDrugBev7CM/r/zhWIxd/C8VcMUFFAKwAo="; # trivalent-aarch64-hash
    rpmSha256 = "6352c5094f6dca80ebba005ebfb08cfebff385623177f0bc55c31414500ac00a"; # trivalent-aarch64-sha256

    # signed repo metadata (moves every publish)
    repomdUrl = "https://repo.secureblue.dev/repodata/repomd.xml";
    repomdHash = "sha256-loI7y7zrMEO/4wlquRvW+HezA6fYzImZ4EEpYY0Iqds=";
    repomdAscUrl = "https://repo.secureblue.dev/repodata/repomd.xml.asc";
    repomdAscHash = "sha256-o5NEm9Y9lcXJvrFiyZExuZEFjDVlnWXKEC/OsOUDw5M=";
    primaryUrl = "https://repo.secureblue.dev/repodata/19c650b7601c2ade6155aef971212e927ce6be6547d9a90949690a8a1d738a37-primary.xml.zst";
    primaryHash = "sha256-GcZQt2AcKt5hVa75cSEuknzmvmVH2akJSWkKih1zijc=";

    # SLSA provenance (immutable per release tag)
    intotoUrl = "https://github.com/secureblue/Trivalent/releases/download/152.0.7977.82-447136/multiple.intoto.jsonl";
    intotoHash = "sha256-vS+GMWUuLoY48UiV4P3YF1MXLgSP2+OGrpTRALHMAxE=";

    # verified: 2026-09-08  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };
}
