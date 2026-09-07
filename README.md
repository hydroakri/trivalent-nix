# trivalent-nix

A standalone Nix flake that packages [secureblue Trivalent](https://github.com/secureblue/Trivalent)
(hardened Chromium) from the upstream signed RPM. The **three-layer supply-chain
verification runs in the build graph** (`lib/verify.nix`, pure + offline): the
RPM only reaches `src` after its body signature, the signed repodata, and the
SLSA provenance all check out, so `nix build` *is* the verification.

Packaging technique (RPM unpack + FHS wrap) is borrowed from
[`quixaq/trivalent-nix`](https://github.com/quixaq/trivalent-nix); its
zero-verification trust baseline is **not** -- this repo is not a fork.

```
nix build github:hydroakri/trivalent-nix#trivalent
nix run   github:hydroakri/trivalent-nix#trivalent
```

Output: `packages.x86_64-linux.{trivalent,supply-chain}`, `nixosModules.default`.

## Adding it to a NixOS system

Wire `trivalent-nix.nixosModules.default` into your host and set the options:

```nix
# flake.nix
inputs.trivalent-nix.url = "github:hydroakri/trivalent-nix";
inputs.trivalent-nix.inputs.nixpkgs.follows = "nixpkgs";   # match your glibc / mesa

# a module
imports = [ trivalent-nix.nixosModules.default ];
programs.trivalent = {
  enable = true;
  apparmor.enable = true;    # opt-in confinement, see below (complain by default)
  apparmor.enforce = false;
};
```

`enable` installs the package (binary + `.desktop` + icons). Options:
`package`, `apparmor.{enable,enforce,denyHomePaths,readableHomePaths}`.

Just the package, no module: `environment.systemPackages = [
trivalent-nix.packages.x86_64-linux.trivalent ];` or `nix profile install
github:hydroakri/trivalent-nix#trivalent`.

### Requirements / caveats

- **Unprivileged user namespaces** must be available (kernel default; some
  hardening profiles turn them off). `buildFHSEnv` and Chromium's renderer
  sandbox both need them.
- **Wayland/Vulkan flags are not applied.** The vendor `trivalent.conf` that
  picks `--ozone-platform=wayland` / `--use-vulkan` lives at `/etc/trivalent/`,
  absent on non-secureblue systems. Wayland still works if the session provides
  it (`NIXOS_OZONE_WL=1`); Vulkan stays off, the browser runs on GL/ANGLE-GLES.
- **No `trivalent-selinux`** -- NixOS has no usable SELinux (store layout is
  incompatible with Fedora's targeted base policy). `programs.trivalent.apparmor`
  is the stand-in; see "Kept vs degraded".
- **No automatic updates** -- `pins.nix` is bumped by hand (see the update cycle).

## Status

| | |
|---|---|
| RPM body signature + signed repodata + SLSA-provenance content, key `26B4…3E41`, in the build graph | **done** -- `lib/verify.nix` / `checks.supply-chain`; Sigstore chain carried by the pinned `intotoHash` (re-verified live by `verify/10-…` before a pin) |
| launches, renders a real page, FHS wrapper doesn't downgrade the sandbox | **done** -- `verify/30-sandbox-selfcheck.sh`; `F4-F5-RESULTS.md` |
| F4 (glibc): binary needs `GLIBC_2.43`, default `glibcStrategy = "fedora-rpm"` | **done** -- `F4-F5-RESULTS.md` |
| F5 (sandbox): unpriv userns + seccomp-bpf, wrapped == unwrapped, no setuid helper | **done** -- `F4-F5-RESULTS.md` |
| AppArmor confinement | **opt-in, complain by default** -- `programs.trivalent.apparmor` |
| CI (version-map + auto-update + alarms) | **not built** -- `verify/*.sh` exit codes are the contract |
| `aarch64` | **not exposed** -- see below |

## verify/ -- the scripts (exit codes are the judgement)

| script | does | key exit codes |
|---|---|---|
| `00-bootstrap-key.sh` | acquire the signing key from **two independent channels**, check both against `fingerprint.env`, cross-check `build.yml`; append a `KEY-PROVENANCE.md` row | `0` ok · `40` mismatch, writes nothing (F1) · `41` network |
| `20-version-map.sh <arch>` | derive "current version" from repodata **and** GitHub independently, classify any disagreement | `0` match (prints `VERSION=`) · `10` repodata lag (retries) · `21` lag past budget · `20` repodata ahead / tag absent = ALARM (F3) · `22` unparseable |
| `10-verify-supply-chain.sh <v-r> <arch> [rpm]` | the same 3 layers as `lib/verify.nix` **plus** the live `slsa-verifier` Sigstore/Rekor chain; prints a ready-to-paste `pins.nix` block. Run this before taking a pin. | `0` = **RESULT: PASS** · `11/12/13` layer 1/2/3 · `30` provenance format changed (F2) · `31` missing · `40` key mismatch |
| `30-sandbox-selfcheck.sh [url]` | strace the wrapped **and** unwrapped browser on a real URL; assert userns + seccomp-bpf, no setuid path, sandbox syscall sets match, DOM non-empty | `0` ok · `50` sandbox inadequate · `53` wrapped≠unwrapped · `52` empty DOM |
| `40-review.sh` | **independent review layer** -- definition-drift, version-map coverage, pass-criterion validity. Run after any edit to `00/10/20` or `fingerprint.env` | `0` = REVIEW: PASS |
| `99-negative-tests.sh` | proves the fail-closed paths (tamper, key flip, F2 30-vs-31, F3 reverse) actually return those codes | `0` = all fail-closed |

These four stay shell because they need network / wall-clock time / a real
kernel -- not expressible as a pure build. They self-bootstrap their CLIs via
`nix shell`, or use `nix develop`. The 3-layer *verification* itself is
`lib/verify.nix` (pure, in the build graph); `10-…` is the wrapper that also
runs the live `slsa-verifier` and emits the pin block.

### One update cycle (manual -- no CI yet)

```
./verify/20-version-map.sh x86_64                 # -> VERSION=<v-r>   (exit 0)
./verify/10-verify-supply-chain.sh <v-r> x86_64   # -> RESULT: PASS + a pins.nix block
# paste the block into pins.nix; keep verify/logs/<v-r>/ committed
./verify/40-review.sh                             # -> REVIEW: PASS
nix flake check                                   # lib/verify.nix re-checks offline
./verify/30-sandbox-selfcheck.sh https://example.org
git commit
```

Order is not optional: `20` exit 0 before `10`; `10` exit 0 before `pins.nix`.

## Trust anchors (`verify/fingerprint.env`)

- signing key fingerprint `26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41` -- the only
  place it is written. Confirmed via (1) `secureblue/Trivalent` `build.yml`
  (`%_gpg_name` + `gpg --detach-sign --local-user`) and (2) the `secureblue.gpg`
  bytes (`sha256 40d8ad27…d555`), byte-identical at `repo.secureblue.dev` and
  committed in `secureblue/secureblue`. See `KEY-PROVENANCE.md`.
- Changing it is a manual edit + a new `KEY-PROVENANCE.md` row with >= 2
  independent channels + a human name. No script adopts a new fingerprint. (F1)

## aarch64

Not exposed until: x86_64 fully green, then `10-verify-supply-chain.sh` re-run
with `aarch64` against the aarch64 RPM and **its own** release tag (secureblue
alternates x86_64 / aarch64 tags). The fingerprint, `--source-uri` and
`--builder-id` are shared (same reusable `build.yml` + generator `@v2.1.0`); the
`--source-branch` / workflow-path pin and the Fedora glibc RPM (URL + hash) are
per-arch. F5's strace run must be redone on real aarch64 hardware.

## Relationship to upstream -- read this

**This is not an upstream-supported way to run Trivalent.** secureblue builds and
ships Trivalent for **Fedora Atomic (rpm-ostree) images only**, where it comes
with a SELinux policy module, distro-level configuration, image-level provenance
verification, and automatic security updates. Running the RPM on NixOS is a
community re-pack, the same category as the AUR `trivalent-bin` and
`quixaq/trivalent-nix` -- neither endorsed nor tested by secureblue. If you want
Trivalent as upstream intends it, install a secureblue image.

Not affiliated with secureblue, Trivalent, or quixaq.

## Drift contract (nixpkgs bumps)

The package is a Fedora RPM patchelf'd against nixpkgs libs and FHS-wrapped, so
nixpkgs movement can break it. It is built so every break is **loud, at build
time, before deploy** -- never a silently broken browser:

`installCheckPhase` (run by `nix build` and `checks.trivalent`, i.e. `nix flake
check`) does four layers on the patched binary, cheapest first:

1. interpreter exists; every direct `DT_NEEDED` resolves by name in the RPATH;
2. **full transitive `ld.so --list` closure** -- any `not found` at any depth
   fails (a runtime lib whose *own* deps drifted);
3. **real load + relocation** (`trivalent --version` in the sandbox) -- catches
   `version \`GLIBC_2.43' not found`, `undefined symbol`, ABI breaks that trace
   mode cannot see;
4. the vendor `trivalent.sh` still `exec bwrap`s (F5).

| drift | caught by |
|---|---|
| a `runtimeLibs` attr renamed/removed (`xorg.libX11` -> `libx11`, ...) | eval error |
| a runtime lib bumps SONAME | layer 1 -> build fails |
| a runtime lib's transitive dep drifts / goes missing | layer 2 -> build fails |
| glibc / a lib becomes ABI-incompatible (`GLIBC_2.x not found`, `undefined symbol`) | layer 3 -> build fails (verified: `glibcStrategy = "nixpkgs"` now fails the build, not just at launch) |
| nixpkgs glibc reaches the Fedora one | nothing breaks -- default `glibcStrategy = "fedora-rpm"` is glibc-version-independent (Fedora GA `glibc-2.43-2.fc44`, frozen tree) |
| `buildFHSEnv` `-bwrap` rename | omen15 build fails, and/or the AppArmor attach glob stops matching -- `CHECK_APPARMOR=1 verify/30-sandbox-selfcheck.sh` |
| upstream rewrites `trivalent.sh` | layer 4 -> build fails |
| GPU/GL regression from a mismatched mesa | runtime only -> `verify/30-sandbox-selfcheck.sh` + `chrome://gpu` |

**After any nixpkgs bump that rebuilds Trivalent, run:**

```
nix build .#trivalent                                   # installCheckPhase
verify/30-sandbox-selfcheck.sh https://example.org      # launch + sandbox + real page
```

Consumed with `inputs.nixpkgs.follows`, Trivalent rides the consumer's nixpkgs.
A chezmoi-style `update-flake-lock.yml` that build-gates + auto-reverts already
turns "drift broke Trivalent" into "PR stays closed, old lock kept" -- because
the checks above make the break a *build* failure. Drop the `follows` and pin
`trivalent-nix`'s own `nixpkgs` if you'd rather freeze it entirely (costs a 2nd
nixpkgs in the closure and risks GL-driver ABI skew against the host).

## Kept vs degraded vs a secureblue install

**Kept**

- Trivalent's Chromium patchset + hardened compile flags -- binary shipped
  byte-for-byte, only ELF interpreter/RPATH patched.
- Intel CET tunables (`x86_ibt`, `x86_shstk`) -- `trivalent.sh` run unmodified.
- Vendor `bwrap --cap-drop ALL` jail + `/etc/ld.so.preload` neutralised.
- Renderer sandbox: namespace (user/PID/net) + seccomp-bpf + TSYNC + broker Yama
  (`chrome://sandbox`: "adequately sandboxed"; strace parity in `F4-F5-RESULTS.md`).
- HW-accelerated canvas/compositing/raster/WebGL + HW video decode/encode
  (`chrome://gpu`).
- Three-layer supply-chain verification of the RPM.

**Degraded / absent**

- `trivalent-selinux` -- no SELinux on NixOS. `programs.trivalent.apparmor` is
  the stand-in (opt-in; read-mostly, `$HOME` blind except the browser's own
  dirs + downloads, hard denies on ssh/gpg/keyrings/history/credential stores).
  Off or in complain mode, the browser process has no MAC confinement.
- GPU process not sandboxed (`chrome://gpu` -> `Sandboxed: false`) under the
  FHS+bwrap wrap; the renderer and network sandboxes are unaffected.
- Vulkan disabled (`/etc/trivalent/trivalent.conf` not read) -- GL/ANGLE-GLES.
- No automatic updates -- `pins.nix` bumped by hand.
- Yama non-broker ptrace protection depends on the host `kernel.yama.ptrace_scope`
  (secureblue uses `3`).
