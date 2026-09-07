# MAINTENANCE

Three things drift on their own schedules. Each has a pinned value and a build
that fails closed when reality stops matching it.

| pinned | file | rotates | procedure |
|---|---|---|---|
| Trivalent version + repodata + provenance | `pins.nix` per-arch block | every upstream release | [update cycle](#per-release-update) |
| secureblue signing key | `verify/fingerprint.env` + `pins.nix` `keyHash` | rarely (key rotation) | [key rotation](#key-rotation-f1) |
| Sigstore trusted root | `verify/sigstore-trusted-root.json` + `pins.nix` `sigstoreTrustedRootSha256` | ~yearly (Sigstore announces) | [trusted-root rotation](#sigstore-trusted-root-rotation) |

---

## Sigstore trusted-root rotation

`lib/verify.nix` layer 3 verifies the SLSA provenance's Sigstore/Rekor
signature chain **offline** against `verify/sigstore-trusted-root.json` (the
Fulcio CA roots + Rekor / CT log public keys). Sigstore rotates this material
occasionally and announces it (blog.sigstore.dev, `sigstore/root-signing`
releases). You need to rotate when:

- Sigstore announces a prod trust-root change, **or**
- `verify/10-verify-supply-chain.sh` starts failing layer 3 with a TUF/trust
  error, **or**
- a new upstream provenance won't verify in the pure build (`FAIL layer3:
  cosign did not print 'Verified OK'`) despite the RPM being genuine.

### Refresh + re-pin

```sh
# 1. fetch the current prod trusted root via the TUF client (needs network)
tmp=$(mktemp -d); HOME=$tmp nix run nixpkgs#cosign -- initialize
cp "$tmp/.sigstore/root/tuf-repo-cdn.sigstore.dev/targets/trusted_root.json" \
   verify/sigstore-trusted-root.json

# 2. sanity-check it is the real thing, not an empty stub
nix run nixpkgs#jq -- -e \
  '(.certificateAuthorities|length>0) and (.tlogs|length>0) and (.ctlogs|length>0)' \
  verify/sigstore-trusted-root.json

# 3. re-pin its hash
sha256sum verify/sigstore-trusted-root.json
#   -> paste the hex into pins.nix  sigstoreTrustedRootSha256 = "...";

# 4. prove the pinned provenance still verifies against the new root
nix build .#supply-chain            # must reach RESULT: PASS
./verify/10-verify-supply-chain.sh "$(grep -oP 'versionRelease = "\K[^"]+' pins.nix | head -1)" x86_64
```

### Record it

Add a line to `KEY-PROVENANCE.md` (it is the append-only trust log for all
pinned crypto material, not only the GPG key):

```
| <date UTC> | sigstore-trusted-root | sha256 <new> | reason: <sigstore announcement URL / TUF error> | by: <name> |
```

Commit `verify/sigstore-trusted-root.json` + `pins.nix` + the `KEY-PROVENANCE.md`
row together. A change to either file without the other fails
`verify/40-review.sh` (and the trusted-root hash check in `lib/verify.nix`).

### If refresh is impossible (Sigstore down, airgapped)

The old root stays valid until Sigstore actually retires it; there is no rush.
Do **not** hand-edit the JSON or bump the pin without a real refreshed file --
the hash check exists precisely to stop that.

---

## Per-release update

```sh
./verify/20-version-map.sh x86_64                 # -> VERSION=<v-r>   (exit 0)
./verify/10-verify-supply-chain.sh <v-r> x86_64   # -> RESULT: PASS + a pins.nix block
#   paste the printed block into pins.nix (x86_64 = { ... };)
#   keep verify/logs/<v-r>/ committed
./verify/40-review.sh                             # -> REVIEW: PASS
nix flake check                                   # lib/verify.nix re-verifies offline
./verify/30-sandbox-selfcheck.sh https://example.org
git commit
```

`20` exit 0 **before** `10`; `10` exit 0 **before** `pins.nix` is touched.
`10-verify` also re-runs `slsa-verifier` with its live Sigstore/Rekor lookup --
belt-and-suspenders over what `lib/verify.nix` does offline.

---

## Key rotation (F1)

A change to `SECUREBLUE_FPR` / `keyHash` is indistinguishable from key theft, so
it is never automated. Run `./verify/00-bootstrap-key.sh` -- it fetches the key
from two independent channels and cross-checks `build.yml`; it only appends a
`KEY-PROVENANCE.md` row, it never writes a new fingerprint. A human edits
`verify/fingerprint.env` + `pins.nix` `keyHash` after >= 2 independent channels
confirm the same new value. `verify/40-review.sh` R1 fails if a fingerprint in
git history has no matching `KEY-PROVENANCE.md` row.
