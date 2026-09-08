# trivalent-nix

[![ci](https://github.com/hydroakri/trivalent-nix/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/hydroakri/trivalent-nix/actions/workflows/ci.yml)

secureblue [Trivalent](https://github.com/secureblue/Trivalent) (hardened
Chromium), repackaged from the upstream signed RPM. Verification runs **in the
build graph**: `nix build` produces the package only after the RPM's GPG body
signature, the GPG-signed repodata, and the SLSA provenance (whole Sigstore/Rekor
chain, offline, via cosign against a vendored trusted root) all check out.

```
nix run github:hydroakri/trivalent-nix#trivalent
```

**x86_64-linux and aarch64-linux** (the only two arches secureblue builds).
Unpack + FHS-wrap technique from
[`quixaq/trivalent-nix`](https://github.com/quixaq/trivalent-nix); its
zero-verification trust baseline is not -- this is not a fork. Outputs:
`packages.{x86_64,aarch64}-linux.{trivalent,supply-chain}`, `nixosModules.default`.

## Install (NixOS)

```nix
inputs.trivalent-nix.url = "github:hydroakri/trivalent-nix";
inputs.trivalent-nix.inputs.nixpkgs.follows = "nixpkgs";   # share your glibc / mesa

imports = [ inputs.trivalent-nix.nixosModules.default ];

programs.trivalent.enable = true;   # required: install the package (binary + .desktop + icons)
security.apparmor.enable  = true;   # OPTIONAL: when on, the Trivalent confinement
                                    # profile (SELinux stand-in) loads, in complain mode
```

`programs.trivalent.enable` is the only required setting.
`security.apparmor.enable` is a system-wide NixOS switch -- this module never
sets it -- and while it is on the Trivalent profile loads automatically. After a
soak (`journalctl -k --grep 'profile="trivalent"'`), make it block:

```nix
security.apparmor.policies.trivalent.state = "enforce";   # or "disable" to drop just this profile
```

Niche knobs: `programs.trivalent.package` (override the package),
`programs.trivalent.apparmor.{denyHomePaths,readableHomePaths}` (extra `@{HOME}`
globs the browser must never touch / may only read).

**Without the module:** `environment.systemPackages = [
inputs.trivalent-nix.packages.${pkgs.system}.trivalent ];` or `nix profile
install github:hydroakri/trivalent-nix#trivalent`. No binary cache is published
-- a repack of a prebuilt RPM, ~2 min to build locally.

## Caveats

- **Unprivileged user namespaces** must be available (kernel default; some
  hardening profiles disable them) -- `buildFHSEnv` and Chromium's renderer
  sandbox both need them.
- **Wayland/Vulkan flags aren't applied** -- the vendor
  `/etc/trivalent/trivalent.conf` is absent on non-secureblue systems. Wayland
  still works via `NIXOS_OZONE_WL=1`; Vulkan stays off (GL/ANGLE-GLES).
- Consumed with `inputs.nixpkgs.follows`, Trivalent rides your nixpkgs; a bad
  bump is a *build* failure ([Drift](#drift-nixpkgs-bumps)), so a build-gated
  `update-flake-lock` auto-reverts. Drop the `follows` to freeze it (2nd nixpkgs
  in the closure; risks GL-driver ABI skew).

## Relationship to upstream -- read this

**Not an upstream-supported way to run Trivalent.** secureblue ships it for
**Fedora Atomic images only**, with a SELinux module, distro config, image-level
provenance, and automatic updates. Running the RPM on NixOS is a community
re-pack, same category as AUR `trivalent-bin` / `quixaq/trivalent-nix` -- neither
endorsed nor tested by secureblue. Not affiliated with secureblue, Trivalent, or
quixaq.

## Status

All green on **x86_64-linux and aarch64-linux**, all in `nix flake check` / CI
(x86_64 on `ubuntu-latest` job `ci-x86_64`, aarch64 on `ubuntu-24.04-arm` job
`ci-aarch64` -- both required):

- **3-layer supply chain** (`checks.supply-chain`, offline, key `26B4…3E41`) --
  cosign against the vendored `verify/sigstore-trusted-root.json` (rotation:
  `MAINTENANCE.md`).
- **nixpkgs-drift gate** (`checks.trivalent` -> `installCheckPhase`) and
  **`checks.launcher-scrub`** (the `LD_PRELOAD` scrub, behavioural) and
  **`verify/40-review.sh`** (independent review: fingerprint + trusted-root pins).
- **F4** (binary needs `GLIBC_2.43` -> pinned Fedora glibc, per arch) and **F5**
  (sandbox parity, no setuid helper) verified -- `F4-F5-RESULTS.md`.
- **Unattended auto-update + drift CI** -- both arches, see [Automation](#automation).

## How the verification works

`lib/verify.nix` is the whole 3-layer check, pure and offline, in the build
graph -- `nix build .#supply-chain` (and `nix flake check`) fail if any layer
does:

1. **RPM body signature** -- `rpmkeys -Kv` against the pinned key.
2. **Signed repodata** -- `gpg --verify repomd.xml.asc`, then bind the RPM's
   sha256 to the `<checksum>` in the signed `primary.xml`.
3. **SLSA provenance** -- cosign verifies the full Sigstore/Rekor chain over the
   `.intoto` bundle offline (pinned trusted root), then a jq policy on the
   statement: subject digest == this RPM, builder id + source uri + branch +
   arch entrypoint == the anchors in `verify/fingerprint.env`.

`verify/` scripts add the parts that can't be a pure build (network, wall-clock,
a real kernel). Exit codes are the judgement:

| script | does | key exit codes |
|---|---|---|
| `10-verify-supply-chain.sh <v-r> <arch> [rpm]` | the 3 layers **plus** a live `slsa-verifier` Sigstore/Rekor lookup; prints a ready-to-paste `pins.nix` block | `0` PASS · `11/12/13` layer 1/2/3 · `30` provenance format changed (F2) · `31` missing · `40` key mismatch |
| `20-version-map.sh <arch>` | derive "current version" from repodata **and** GitHub independently, classify disagreement | `0` match (`VERSION=`) · `10`/`21` repodata lag · `20` repodata ahead / tag absent (F3) · `22` unparseable |
| `00-bootstrap-key.sh` | acquire the key from **two independent channels**, check both vs `fingerprint.env`, append a `KEY-PROVENANCE.md` row | `0` ok · `40` mismatch, writes nothing (F1) · `41` network |
| `30-sandbox-selfcheck.sh [url]` | strace wrapped **and** unwrapped browser on a real URL: userns + seccomp-bpf, no setuid path, sets match, DOM non-empty, `LD_PRELOAD` sentinel never reaches the browser | `0` ok · `50` sandbox inadequate · `52` empty DOM · `53` wrapped≠unwrapped · `55` preload reached the browser |
| `40-review.sh` | independent review layer (R1 fingerprint, R2 version-map, R3 pass-criterion, R4 trusted-root). In `ci.yml`. | `0` REVIEW: PASS |
| `99-negative-tests.sh` | proves the fail-closed paths return those codes | `0` all fail-closed |

## Automation

`nix run .#update` (`lib/update.nix`, a Nix-built `writeShellApplication`, also
`packages.trivalent.passthru.updateScript`) is the whole update: preflight once
(key + trusted-root pins, mismatch -> `HALT.txt` + exit 40/41, no writes) -> for
**each arch** `20-version-map.sh` -> `10-verify-supply-chain.sh` (+ writes
`verify/logs/<v-r>/`) -> rewrite that arch's `pins.nix` block -> x86_64
`.#supply-chain` re-verify (aarch64 gated by `ci-aarch64`) -> emit the
`updateScript` JSON. Exit: `0` bump/no-op · `20` F3 · `22`
unparseable · `30` F2 · `40/41` key/trusted-root HALT · `42` key rotation
**PROPOSED** · `11/12/13` a layer failed.

**Key rotation (F1)** is semi-automated: a new `repo.secureblue.dev` key is
checked against four independent channels (R2, the key in `secureblue/secureblue`,
`%_gpg_name` in `secureblue/Trivalent` `build.yml`, and whether the **old** key
carries a verified certification over the new one from `keyserver.ubuntu.com` --
unforgeable by an endpoint-only attacker). All four agreeing -> the updater
rewrites the anchors and exits 42; the workflow opens a `needs-human-approval`
PR that is **never auto-merged**, and `40-review.sh` R1 keeps `ci-x86_64` red until a
human confirms a further channel and signs the `KEY-PROVENANCE.md` row. Any
channel missing -> exit 40, fully manual.

| workflow | trigger | does |
|---|---|---|
| `ci.yml` | PR + push to main | `nix flake check` + `nix build .#trivalent .#supply-chain` + `40-review.sh`. **The required check.** |
| `update-trivalent.yml` | daily | `nix run .#update`; HALT -> `blocked`+`security` issue; else working-tree guard (`pins.nix` + `verify/logs/` only) -> pre-PR `nix flake check` -> PR -> **auto-merge on green** (retry / rollback-and-close on red). |
| `update-flake-lock.yml` | daily | health-gate -> staleness (only if `.#trivalent.drvPath` moves) -> `nix flake update` -> `nix flake check` + build -> PR -> auto-merge/rollback. |

A wrong auto-pin -> `checks.supply-chain` / `installCheckPhase` red -> PR closed,
`main` never advances. The two F1 decisions halt to an issue and are done by a
human per `MAINTENANCE.md`. Repo prerequisites: secret `GH_TOKEN_FOR_UPDATES`,
"Allow auto-merge" on, branch protection requiring `ci-x86_64` + `ci-aarch64`.

**Bump by hand:** `nix run .#update` -> `./verify/40-review.sh` -> `nix flake
check` -> `git add pins.nix verify/logs && git commit`.

## Trust anchors (`verify/fingerprint.env`)

Signing key `26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41` -- the only place it is
written. Confirmed via `secureblue/Trivalent` `build.yml` (`%_gpg_name` +
`gpg --detach-sign`) and the `secureblue.gpg` bytes (`sha256 40d8ad27…d555`),
byte-identical at `repo.secureblue.dev` and in `secureblue/secureblue`. Changing
it is a manual edit + a `KEY-PROVENANCE.md` row with >= 2 independent channels
and a human name; no script adopts a new fingerprint (F1).

## aarch64

First-class -- same 3-layer verification, gated on a native `ubuntu-24.04-arm`
CI job (`ci-aarch64`, required); the updater bumps both arches. Release-tag-pair
and per-arch mechanics: `MAINTENANCE.md`.

## Compared to building from source (nixpkgs#531708)

An open nixpkgs PR builds Trivalent **from source** on nixpkgs' Chromium
infrastructure. Different trade-off:

| | from source (#531708) | this flake (repack the signed RPM) |
|---|---|---|
| GN hardening flags | hand-mirrored from `trivalent.spec` into `gnFlags`; drifts on every upstream change | inherited -- secureblue's compiled output, nothing to mirror |
| launcher hardening (`LD_*` scrub, Intel CET, `crbug.com/376567` stdio, refuse-root) | re-implemented in a `makeWrapper` wrapper | inherited -- `trivalent.sh` runs unmodified |
| Chromium-version coupling | `broken = chromium != "<pinned>"`; breaks each nixpkgs Chromium bump until a human re-syncs patches | none -- the binary is self-contained |
| build cost | 48 h timeout, `big-parallel`, needs a cache | minutes, no cache |
| trust | `fetchFromGitHub` hash | GPG sig + signed repodata + SLSA/Sigstore, in the build graph |
| cost | native Nix libs throughout | binary artifact + a pinned Fedora glibc (F4) |

This one optimises for *running exactly what secureblue signed*, cheaply, with
the supply chain checked.

## Drift (nixpkgs bumps)

The package is a Fedora RPM patchelf'd against nixpkgs libs and FHS-wrapped, so
nixpkgs movement can break it -- always **loud, at build time, before deploy**.
`installCheckPhase` (`nix build` / `checks.trivalent`) does four layers on the
patched binary: (1) interpreter + every direct `DT_NEEDED` resolves in RPATH;
(2) full transitive `ld.so --list` closure, any `not found` fails; (3) real
load + relocation (`trivalent --version`) -- catches `GLIBC_2.x not found`,
`undefined symbol`; (4) the vendor `trivalent.sh` still `exec bwrap`s.

| drift | caught by |
|---|---|
| a `runtimeLibs` attr renamed/removed | eval error |
| a runtime lib bumps SONAME | layer 1 |
| a transitive dep drifts / goes missing | layer 2 |
| glibc / a lib ABI-incompatible | layer 3 (`glibcStrategy = "nixpkgs"` fails the build, not just at launch) |
| nixpkgs glibc reaches the Fedora one | nothing breaks -- default `glibcStrategy = "fedora-rpm"` is version-independent (frozen `glibc-2.43-2.fc44`) |
| upstream rewrites `trivalent.sh` | layer 4 |
| upstream drops/moves the `LD_PRELOAD` scrub | `checks.launcher-scrub` red; `verify/30` exit 55 (the `env -u` wrapper still holds -- the check just surfaces it) |
| `buildFHSEnv` `-bwrap` rename / stops honouring `extraBwrapArgs` | build fails / `checks.launcher-scrub` WIRING FAIL; AppArmor attach glob -- `CHECK_APPARMOR=1 verify/30-sandbox-selfcheck.sh` |
| GPU/GL regression from mismatched mesa | runtime only -- `verify/30` + `chrome://gpu` |

After any nixpkgs bump that rebuilds Trivalent: `nix build .#trivalent` +
`verify/30-sandbox-selfcheck.sh https://example.org`.

## Kept vs degraded vs a secureblue install

**Kept** -- Chromium patchset + hardened compile flags (binary byte-for-byte,
only ELF interpreter/RPATH patched); Intel CET tunables + `crbug.com/376567`
stdio hardening (from `trivalent.sh` unmodified); `LD_PRELOAD`/`LD_AUDIT`/
`LD_PROFILE`/`LD_LIBRARY_PATH` kept out of Chromium -- **owned** via the
buildFHSEnv `env -u` `runScript` + `extraBwrapArgs` masking `/etc/ld.so.preload`,
not merely inherited (`checks.launcher-scrub` + `verify/30` exit 55 catch a
regression); vendor `bwrap --cap-drop ALL` jail; renderer sandbox (userns +
seccomp-bpf + TSYNC + broker Yama, `chrome://sandbox`: "adequately sandboxed");
HW-accelerated canvas/WebGL + HW video decode/encode; the 3-layer supply-chain
check.

**Degraded / absent** --

- `trivalent-selinux`: no SELinux on NixOS. The AppArmor profile is the stand-in
  (auto-loaded with `security.apparmor.enable`; read-mostly, `$HOME` blind
  except the browser's own dirs + downloads, hard denies on
  ssh/gpg/keyrings/history/credential stores). AppArmor off or `state =
  "complain"` -> no MAC confinement.
- GPU process not sandboxed (`chrome://gpu` -> `Sandboxed: false`) under the
  FHS+bwrap wrap; renderer and network sandboxes unaffected.
- Vulkan disabled (`/etc/trivalent/trivalent.conf` not read) -- GL/ANGLE-GLES.
- Yama non-broker ptrace protection depends on the host
  `kernel.yama.ptrace_scope` (secureblue uses `3`).
