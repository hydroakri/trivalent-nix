# SLSA provenance verification -- the ONE place that knows the statement shapes.
# Sourced, not executed. Used by verify/10-verify-supply-chain.sh (live) and by
# lib/verify.nix (pure, offline build), so the two cannot drift apart.
#
# Two upstream formats exist (failure mode F2 was the switch between them):
#   v0.2  until 2026-10   asset multiple.intoto.jsonl, signed by slsa-github-generator
#                         (generator_generic_slsa3.yml), predicate.builder/invocation
#   v1    since 2026-11   asset provenance.intoto.json, signed by
#                         slsa-framework/actions attest_actions.yml, predicate
#                         buildDefinition/runDetails
# Both are a Sigstore bundle whose DSSE payload is the in-toto statement. The
# format is read from the (not yet trusted) predicateType ONLY to choose which
# anchors to check; cosign then verifies the signature chain, and an unknown
# predicateType fails closed.

# prov_predicate_type <bundle>
prov_predicate_type() {
  jq -r '.dsseEnvelope.payload | @base64d | fromjson | .predicateType' "$1"
}

# prov_verify_bundle <bundle> <trusted-root> <rpm-sha256> <signer-id>
#   <legacy-builder-id> <source-uri> <source-branch>
# Sigstore chain, offline. Prints cosign's output; returns non-zero unless it
# printed "Verified OK".
prov_verify_bundle() {
  local bundle=$1 root=$2 sha=$3 signer=$4 legacy=$5 uri=$6 branch=$7
  local ptype bid_re out
  ptype="$(prov_predicate_type "$bundle")" || return 1
  case "$ptype" in
  https://slsa.dev/provenance/v1)
    # identity = the attesting workflow; the repo/ref extensions bind the run
    # to the source repository and branch that triggered it.
    out="$(cosign verify-blob-attestation \
      --bundle "$bundle" \
      --trusted-root "$root" \
      --certificate-identity "$signer" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      --certificate-github-workflow-repository "${uri#github.com/}" \
      --certificate-github-workflow-ref "refs/heads/$branch" \
      --type slsaprovenance1 \
      --digest "$sha" --digestAlg sha256 2>&1)" || {
      printf '%s\n' "$out"
      return 1
    }
    ;;
  https://slsa.dev/provenance/v0.2)
    bid_re="$(printf '%s' "$legacy" | sed 's/[.[\*^$()+?{|]/\\&/g')"
    out="$(cosign verify-blob-attestation \
      --bundle "$bundle" \
      --trusted-root "$root" \
      --certificate-identity-regexp "^${bid_re}\$" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      --type slsaprovenance \
      --digest "$sha" --digestAlg sha256 2>&1)" || {
      printf '%s\n' "$out"
      return 1
    }
    ;;
  *)
    echo "unrecognised predicateType: $ptype"
    return 1
    ;;
  esac
  printf '%s\n' "$out"
  printf '%s\n' "$out" | grep -q '^Verified OK$'
}

# prov_policy <statement.json> <arch> <v-r> <rpm-sha256> <legacy-builder-id>
#   <source-uri> <source-branch>
# Policy on the (already cryptographically trusted) statement. Prints the
# reason and returns 1 on any mismatch.
prov_policy() {
  local st=$1 arch=$2 vr=$3 sha=$4 legacy=$5 uri=$6 branch=$7
  local ptype wf="" ref="refs/heads/$branch"
  ptype="$(jq -r '.predicateType' "$st")"
  wf=".github/workflows/build_$arch.yml"
  jq -e --arg n "trivalent-$vr.$arch.rpm" --arg h "$sha" \
    '.subject[] | select(.name==$n) | .digest.sha256==$h' "$st" >/dev/null ||
    {
      echo "no subject trivalent-$vr.$arch.rpm with digest $sha"
      return 1
    }
  case "$ptype" in
  https://slsa.dev/provenance/v1)
    jq -e --arg b "https://$uri/$wf@$ref" '.predicate.runDetails.builder.id==$b' "$st" >/dev/null ||
      {
        echo "runDetails.builder.id != https://$uri/$wf@$ref"
        return 1
      }
    jq -e --arg r "https://$uri" '.predicate.buildDefinition.externalParameters.repository==$r' "$st" >/dev/null ||
      {
        echo "externalParameters.repository != https://$uri"
        return 1
      }
    jq -e --arg r "$ref" '.predicate.buildDefinition.externalParameters.ref==$r' "$st" >/dev/null ||
      {
        echo "externalParameters.ref != $ref"
        return 1
      }
    jq -e --arg w "$wf" '.predicate.buildDefinition.externalParameters.workflow==$w' "$st" >/dev/null ||
      {
        echo "externalParameters.workflow != $wf"
        return 1
      }
    jq -e --arg u "git+https://$uri@$ref" \
      'any(.predicate.buildDefinition.resolvedDependencies[]?; .uri==$u)' "$st" >/dev/null ||
      {
        echo "no resolvedDependency git+https://$uri@$ref"
        return 1
      }
    ;;
  https://slsa.dev/provenance/v0.2)
    jq -e --arg b "$legacy" '.predicate.builder.id==$b' "$st" >/dev/null ||
      {
        echo "predicate.builder.id != $legacy"
        return 1
      }
    jq -e --arg u "git+https://$uri@$ref" '.predicate.invocation.configSource.uri==$u' "$st" >/dev/null ||
      {
        echo "configSource.uri != git+https://$uri@$ref"
        return 1
      }
    jq -e --arg e "$wf" '.predicate.invocation.configSource.entryPoint==$e' "$st" >/dev/null ||
      {
        echo "configSource.entryPoint != $wf"
        return 1
      }
    ;;
  *)
    echo "unrecognised predicateType: $ptype"
    return 1
    ;;
  esac
}
