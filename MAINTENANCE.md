# MAINTENANCE

Three things drift on their own schedules. Each has a pinned value and a build
that fails closed when reality stops matching it.

| pinned | file | rotates | procedure |
|---|---|---|---|
| Trivalent version + repodata + provenance | `pins.nix` per-arch block | every upstream release | [update cycle](#per-release-update) |
| secureblue signing key | `verify/fingerprint.env` + `pins.nix` `keyHash` | rarely (key rotation) | [key rotation](#key-rotation-f1) |
| Sigstore trusted root | `verify/sigstore-trusted-root.json` + `pins.nix` `sigstoreTrustedRootSha256` | ~yearly (Sigstore announces) | [trusted-root rotation](#sigstore-trusted-root-rotation) |

---

## Repository setup

One-time, on `github.com/hydroakri/trivalent-nix`, so the unattended workflows
can open and merge their own PRs. Without these, `update-trivalent.yml` /
`update-flake-lock.yml` fail fast at the `Require GH_TOKEN_FOR_UPDATES` step or
can't merge.

### 1. `GH_TOKEN_FOR_UPDATES` secret

The default `GITHUB_TOKEN` can't trigger `ci` on a bot-pushed branch (pushes
from `GITHUB_TOKEN` don't start `workflow` runs), so auto-merge would wait
forever. Use a personal access token:

- Fine-grained PAT (preferred): **Only select repositories -> hydroakri/trivalent-nix**,
  Repository permissions: **Contents: Read and write**, **Pull requests: Read and
  write**. (That's all the workflows call: `git push`, `gh pr create/merge/close`,
  `gh issue create/comment`.)
- or a classic PAT with the `repo` scope.

Add it at **Settings -> Secrets and variables -> Actions -> New repository
secret**, name `GH_TOKEN_FOR_UPDATES`.

### 2. "Allow auto-merge"

**Settings -> General -> Pull Requests -> Allow auto-merge**. The version-bump
job merges with `gh pr merge --squash` only after `gh pr checks --watch` goes
green; the key-rotation job never merges.

### 3. Branch protection on `main`

**Settings -> Branches -> Add branch ruleset** (or classic rule) for `main`:

- **Require status checks to pass** -> add **`ci`** (the job in `ci.yml`; it
  appears in the list after the first PR runs it once).
- **Require a pull request before merging** (the bot always uses a PR anyway).
- Leave `matrix-nixpkgs` **out** of the required set -- it is `continue-on-error`
  and only a drift signal.

This is what makes auto-merge safe: a bad pin -> `checks.supply-chain` /
`installCheckPhase` red -> `ci` red -> the `Wait for CI, merge or roll back`
step closes the PR, `main` never moves.

### 4. Labels

The workflows pass `--label` and fail if the label doesn't exist. Create:
`automated`, `dependencies`, `blocked`, `security`, `needs-human-approval`.

```sh
for l in automated dependencies blocked security needs-human-approval; do
  gh label create "$l" --repo hydroakri/trivalent-nix 2>/dev/null || true
done
```

### 5. (optional) Actions permissions

**Settings -> Actions -> General -> Workflow permissions**: "Read repository
contents" is enough -- every write goes through `GH_TOKEN_FOR_UPDATES`, not the
default token. No need to grant the default token write.

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

Unattended via `.github/workflows/update-trivalent.yml` (daily -> `nix run
.#update` -> `nix flake check` -> auto-merge on green). By hand:

```sh
nix run .#update            # preflight -> discover -> verify (live) -> rewrite
                            # pins.nix + verify/logs/<v-r>/ -> nix build
                            # .#supply-chain -> print the updateScript JSON
./verify/40-review.sh       # -> REVIEW: PASS
nix flake check
git add pins.nix verify/logs && git commit
```

`nix run .#update` HALTs (writes `HALT.txt`, exits 20/22/30/40/41, touches
nothing) on F1/F2/F3 -- key change, trusted-root mismatch, provenance format
change, repodata ahead of GitHub. The CI turns a HALT into a `blocked` GitHub
issue; resolve it with the procedures in this file.

---

## Key rotation (F1)

A new `SECUREBLUE_FPR` / `keyHash` is indistinguishable from key theft, so it is
never **auto-adopted**. Two paths:

### Semi-automated (the common case)

`nix run .#update` / `update-trivalent.yml` detects the new key and checks four
independent channels: (A) `repo.secureblue.dev`, (B) the key committed in
`secureblue/secureblue`, (C) `%_gpg_name` in `secureblue/Trivalent`
`build.yml`, (D) whether the **old** key -- fetched from `keyserver.ubuntu.com`
-- carries a *verified* signature over the new key (a self-certified rotation;
an endpoint-only attacker can't forge this).

- **All four pass** -> the updater rewrites `verify/fingerprint.env` +
  `pins.nix` `keyHash` + appends a `KEY-PROVENANCE.md` row ending
  `PROPOSED-BY-BOT`, exits 42. The workflow opens a `needs-human-approval` PR
  that is **not auto-merged**. `verify/40-review.sh` R1 fails while the row says
  `PROPOSED-BY-BOT`.
- **You**: confirm the rotation via a channel not in A-D -- secureblue's
  announcement / Discord / release notes -- then on the PR branch edit the last
  `KEY-PROVENANCE.md` row, replacing `PROPOSED-BY-BOT -- confirm ...` with your
  name and the channel you used. Push. `ci` goes green; merge.

### Fully manual (evidence incomplete -> exit 40)

If any of A-D fails (channels disagree, no self-certification, keyserver down):
run `./verify/00-bootstrap-key.sh` (checks A/B/C, only ever appends a row,
never writes a fingerprint), independently confirm >= 2 channels agree on the
new value, then hand-edit `verify/fingerprint.env` + `pins.nix` `keyHash` +
add a `KEY-PROVENANCE.md` row with your name. `40-review.sh` R1/R4 block a
fingerprint or trusted-root value in git history with no matching row.
