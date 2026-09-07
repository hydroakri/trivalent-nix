# Verified upstream pins. Every value here for a given <version-release> is one
# that verify/10-verify-supply-chain.sh returned RESULT: PASS for, with the log
# retained at verify/logs/<version-release>/.
#
# Update flow (manual for now -- "no CI yet"):
#   1. ./verify/20-version-map.sh <arch>            -> VERSION=<v-r>   (exit 0)
#   2. ./verify/10-verify-supply-chain.sh <v-r> <arch>   -> RESULT: PASS + SRI=
#   3. edit the block below; keep verify/logs/<v-r>/ committed
#   4. re-run the independent review checklist (see README)
{
  x86_64 = {
    versionRelease = "152.0.7977.82-447128"; # trivalent-x86_64-vr
    version = "152.0.7977.82"; # trivalent-x86_64-ver
    url = "https://repo.secureblue.dev/Packages/trivalent-152.0.7977.82-447128.x86_64.rpm"; # trivalent-x86_64-url
    hash = "sha256-bdMv+VmQ8JYUAE4+Y1I3kiTe2OOfe8Qlsnt1+bE/qn4="; # trivalent-x86_64-hash
    # verified: 2026-09-07  layers 1+2+3 = 0/0/0  key 26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41
  };

  # aarch64 intentionally absent: not enabled until the x86_64 path is fully
  # green AND 10-verify-supply-chain.sh is re-run natively for aarch64 with its
  # own release tag + Fedora glibc pin. See README "aarch64".
}
