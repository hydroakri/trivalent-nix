# trivalent-nix

A standalone Nix flake that packages [secureblue Trivalent](https://github.com/secureblue/Trivalent)
(hardened Chromium) from the upstream signed RPM, behind **three independent
supply-chain checks** whose logs ship inside the built package.

Packaging technique (RPM unpack + FHS wrap) is borrowed from
[`quixaq/trivalent-nix`](https://github.com/quixaq/trivalent-nix); its
zero-verification trust baseline is **not** -- this repo is not a fork.

```
nix build github:hydroakri/trivalent-nix#trivalent
nix run   github:hydroakri/trivalent-nix#trivalent
```

Output: `packages.x86_64-linux.trivalent` (+ `.default`), `nixosModules.default`.

## Adding it to a NixOS system

`nixosModules.default` just adds the package to `environment.systemPackages`
(which installs the binary, the `.desktop` entry and icons). Wire it as a flake
input:

```nix
# flake.nix
{
  inputs.trivalent-nix.url = "github:hydroakri/trivalent-nix";
  inputs.trivalent-nix.inputs.nixpkgs.follows = "nixpkgs";   # match your glibc

  outputs = { nixpkgs, trivalent-nix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        trivalent-nix.nixosModules.default
      ];
    };
  };
}
```

Or without the module, just the package:

```nix
environment.systemPackages = [ trivalent-nix.packages.x86_64-linux.trivalent ];
```

Home-Manager / imperative: `nix profile install github:hydroakri/trivalent-nix#trivalent`.

### Will it actually run?

Tested working on `omen15` (x86_64, CachyOS kernel): the browser launches,
renders real pages, and the renderer sandbox verifies (`verify/30-sandbox-selfcheck.sh`).
Requirements and known gaps:

- **Unprivileged user namespaces must be enabled** (`kernel.unprivileged_userns_clone = 1`,
  `user.max_user_namespaces` > 0). `buildFHSEnv` needs them to build its sandbox
  and Chromium needs them for the renderer sandbox. If your hardening profile
  disables userns, this package will not run sandboxed (and won't run at all
  under the FHS wrapper).
- **Wayland/Vulkan flags are not applied.** The vendor `trivalent.conf` that
  picks `--ozone-platform=wayland` / `--use-vulkan` lives at `/etc/trivalent/`,
  which the FHS sandbox takes from the host, so it is absent on non-secureblue
  systems. Wayland still works if the session provides it (`NIXOS_OZONE_WL=1`,
  or pass `--ozone-platform=wayland` / `USE_WAYLAND=true`); Vulkan stays off
  and the browser runs on GL/ANGLE-GLES.
- **No `trivalent-selinux`.** secureblue ships a companion SELinux policy module.
  This is a **NixOS platform limitation, not a packaging gap**: NixOS has no
  usable SELinux policy (the store layout is incompatible with Fedora's targeted
  base policy, which `trivalent-selinux` only extends). The MAC layer would have
  to be re-provided with AppArmor or nixpak (see below); nothing this flake does
  can carry it over.
- **No automatic updates.** Until the CI (deferred) exists, `pins.nix` is bumped
  by hand. A browser you do not update is a real risk -- budget for the manual
  update cycle below, or do not rely on this yet.

## Status of the guarantees

| Guarantee | State |
|---|---|
| RPM body signature, signed repodata, SLSA provenance all verified, key traced to `26B4…3E41`, logs retained in `$out/share/trivalent/supply-chain-logs/` | **done** -- `verify/10-verify-supply-chain.sh` exit 0 = all three |
| Launches, renders a real page, sandbox not silently downgraded by the FHS wrapper | **done, measured on omen15** -- `verify/30-sandbox-selfcheck.sh`; see `F4-F5-RESULTS.md` |
| glibc compatibility (F4) | **measured on omen15** -- vendor binary needs `GLIBC_2.43`; default `glibcStrategy = "fedora-rpm"`. `F4-F5-RESULTS.md` |
| Sandbox strength (F5) | **measured on omen15** -- unprivileged userns + seccomp-bpf, identical wrapped vs unwrapped, no setuid helper in the RPM. `F4-F5-RESULTS.md` |
| CI (version-map + auto-update + alarms) | **not built** -- deferred by choice. `verify/*.sh` exit codes are the contract a future workflow consumes. |
| `aarch64` | **not exposed** -- see below |

Nothing here is "measured" until `F4-F5-RESULTS.md` says so for the current
Trivalent version. Re-run the F4 build and `verify/30-sandbox-selfcheck.sh` on a
version bump whose changelog touches the launcher, sandbox, or build toolchain.

## verify/ -- the scripts (exit codes are the judgement)

| script | does | key exit codes |
|---|---|---|
| `00-bootstrap-key.sh` | acquire the signing key from **two independent channels**, check both against `fingerprint.env`, cross-check `build.yml`; append a `KEY-PROVENANCE.md` row | `0` ok · `40` mismatch, writes nothing (F1) · `41` network |
| `20-version-map.sh <arch>` | derive "current version" from repodata **and** GitHub independently, classify any disagreement | `0` match (prints `VERSION=`) · `10` repodata lag (retries) · `21` lag past budget · `20` repodata ahead / tag absent = ALARM (F3) · `22` unparseable |
| `10-verify-supply-chain.sh <v-r> <arch> [rpm]` | layer 1 `rpmkeys -Kv` · layer 2 `gpg --verify repomd.xml.asc` + bind RPM sha256 to the signed `primary.xml` · layer 3 `slsa-verifier` with builder + source-uri + source-branch pinned | `0` = **RESULT: PASS** (all three) · `11/12/13` layer 1/2/3 failed · `30` provenance format changed (F2, ≠ missing) · `31` provenance missing · `40` key mismatch |
| `30-sandbox-selfcheck.sh [url]` | strace the wrapped **and** unwrapped browser on a real URL; assert userns + seccomp-bpf, no setuid path, sandbox syscall sets match, DOM non-empty | `0` ok · `50` sandbox inadequate · `53` wrapped≠unwrapped · `52` empty DOM |
| `40-review.sh` | **independent review layer** -- definition-drift, version-map coverage, pass-criterion validity. Run after any edit to `00/10/20` or `fingerprint.env` | `0` = REVIEW: PASS |
| `99-negative-tests.sh` | proves the fail-closed paths (tamper, key flip, F2 30-vs-31, F3 reverse) actually return those codes | `0` = all fail-closed |

The scripts self-bootstrap their CLIs via `nix shell` if missing, or use
`nix develop` for the full toolchain.

### One update cycle (manual -- no CI yet)

```
./verify/20-version-map.sh x86_64                 # -> VERSION=<v-r>   (exit 0)
./verify/10-verify-supply-chain.sh <v-r> x86_64   # -> RESULT: PASS + SRI=
# edit pins.nix with <v-r> / version / url / SRI; keep verify/logs/<v-r>/ committed
./verify/40-review.sh                             # -> REVIEW: PASS
nix build .#trivalent && ./verify/30-sandbox-selfcheck.sh https://example.org
git commit
```

`20-version-map.sh` must reach exit 0 **before** `10-verify` runs; `10-verify`
must reach exit 0 **before** `pins.nix` is touched. Order is not optional.

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

## Kept vs degraded (measured on omen15, Trivalent 152.0.7977.82)

**Kept**

- Trivalent's Chromium patchset + hardened compile flags -- the binary is shipped
  byte-for-byte, only ELF interpreter/RPATH patched for glibc 2.43.
- Intel CET tunables (`glibc.cpu.x86_ibt=on`, `x86_shstk`) -- `trivalent.sh` run unmodified.
- Vendor `bwrap --cap-drop ALL` jail + `/etc/ld.so.preload` neutralised -- same.
- Renderer sandbox: namespace (user/PID/net) + seccomp-bpf + TSYNC + broker Yama
  -- `chrome://sandbox` reports "adequately sandboxed"; strace parity wrapped vs
  unwrapped (`F4-F5-RESULTS.md`).
- Wayland/ozone active, HW-accelerated canvas/compositing/raster/WebGL and HW
  video decode+encode (`chrome://gpu`).
- Three-layer supply-chain verification of the RPM (`verify/`).

**Degraded / absent**

- `trivalent-selinux`: **NixOS has no usable SELinux** (platform limitation, not a
  packaging gap) and no AppArmor profile ships here -- the browser process runs
  with **no MAC confinement**. Recover it with AppArmor or nixpak, not SELinux.
- GPU process is **not sandboxed** (`chrome://gpu` -> `Sandboxed: false`) under the
  FHS+bwrap wrap; the renderer and network sandboxes are unaffected.
- Vulkan disabled -- secureblue's `/etc/trivalent/trivalent.conf` (which sets
  `--use-vulkan`) is not read; runs on GL/ANGLE-GLES instead.
- No automatic updates -- `pins.nix` bumped by hand until CI exists.
- Yama non-broker ptrace protection off -- host `kernel.yama.ptrace_scope = 1`
  (`security.nix`); secureblue uses `3`.
