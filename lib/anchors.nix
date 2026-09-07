# Single source of truth for the supply-chain trust anchors, parsed from
# verify/fingerprint.env so the shell scripts and the Nix build read the same
# file. Only the plain `NAME=VALUE` lines are exposed (the overridable
# `: "${NAME:=...}"` coordinate vars are shell-test plumbing, not anchors).
{ lib }:
let
  raw = builtins.readFile ../verify/fingerprint.env;
  lines = lib.splitString "\n" raw;
  parse =
    l:
    let
      m = builtins.match "([A-Z_][A-Z0-9_]*)=(.+)" l;
    in
    if m == null then
      null
    else
      {
        name = builtins.head m;
        value = builtins.elemAt m 1;
      };
  env = builtins.listToAttrs (builtins.filter (x: x != null) (map parse lines));
  need = n: env.${n} or (throw "anchors.nix: verify/fingerprint.env is missing ${n}");
in
{
  fpr = need "SECUREBLUE_FPR"; # 40-hex GPG primary-key fingerprint
  fprShort = lib.toLower (lib.substring 32 8 (need "SECUREBLUE_FPR")); # last 8 (rpm-sequoia key id)
  gpgSha256 = need "SECUREBLUE_GPG_SHA256"; # sha256 hex of secureblue.gpg
  slsaBuilderId = need "SLSA_BUILDER_ID";
  slsaSourceUri = need "SLSA_SOURCE_URI"; # e.g. github.com/secureblue/Trivalent
  slsaSourceBranch = need "SLSA_SOURCE_BRANCH"; # e.g. live
}
