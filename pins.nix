# Verified upstream pins. Every hash here was produced by
# verify/10-verify-supply-chain.sh for the given <version-release> (it does the
# full check, incl. the live slsa-verifier Sigstore/Rekor chain, and prints a
# ready-to-paste block). lib/verify.nix then RE-checks all of it offline as part
# of `nix build` -- layers 1+2 fully, layer 3 by binding the provenance CONTENT
# (subject hash + builder/source identity) to this exact RPM. The Sigstore
# signature chain itself is not re-verified in the pure build (slsa-verifier
# needs network); trust in it is carried by `intotoHash` being pinned.
#
# Update flow (manual -- no CI yet):
#   1. ./verify/20-version-map.sh <arch>                 -> VERSION=<v-r>
#   2. ./verify/10-verify-supply-chain.sh <v-r> <arch>   -> RESULT: PASS + pins block
#   3. paste the block below; keep verify/logs/<v-r>/ committed
#   4. ./verify/40-review.sh                             -> REVIEW: PASS
{
  # constant across versions: the signing key, fetched and checked against
  # SECUREBLUE_GPG_SHA256 / the fingerprint in lib/anchors.nix.
  keyUrl = "https://repo.secureblue.dev/secureblue.gpg";
  keyHash = "sha256-QNitJxS7CYcxU2aNnGRzYqzEhneiwN77DH1ldgQf1VU=";

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

  # aarch64 intentionally absent -- see README "aarch64".
}
