# F4 / F5 -- test results

Both failure modes were resolved by running both branches on the target, not by
assuming one.

- **x86_64**: host **omen15** (CachyOS kernel), 2026-09-07, Trivalent
  `152.0.7977.82-447128`, nixpkgs-unstable (`glibc 2.42`). Sections below.
- **aarch64**: `ci-aarch64` on a native `ubuntu-24.04-arm` runner + a manual
  hardware run, 2026-09-08, Trivalent `152.0.7977.82-447136`. See "[aarch64](#aarch64)".

Re-run `verify/30-sandbox-selfcheck.sh` and the F4 build below whenever the
Trivalent version bumps **and** its changelog touches the launcher / sandbox /
build toolchain. A plain version bump does not require re-deciding.

---

## F4 -- glibc symbol compatibility

**Question:** can the vendor binary run against nixpkgs glibc (Branch A), or does
it need a Fedora glibc (Branch B)?

**Measurement.** `readelf -V` on `usr/lib64/trivalent/trivalent`:
```
required GLIBC symbol versions (max): ... GLIBC_2.38 GLIBC_2.42 GLIBC_2.43
```
The binary references **`GLIBC_2.43`**; nixpkgs-unstable ships **`glibc 2.42`**.

**Branch A** (`glibcStrategy = "nixpkgs"`, `autoPatchelfHook`, no bundled glibc):
builds cleanly, `auto-patchelf: 0 dependencies could not be satisfied`, then at
launch:
```
.../trivalent: /lib/libm.so.6: version `GLIBC_2.43' not found (required by .../trivalent)
```
=> **Branch A fails at load time.** Retained in `lib/mk-trivalent.nix` as a
runnable option so the failure is reproducible, not deleted.

**Branch B** (`glibcStrategy = "fedora-rpm"`, default): interpreter +
`RPATH` prefix set to a Fedora 44 `glibc-2.43-2.fc44` tree
(`lib/mk-glibc-rpm.nix`). Result:
```
$ result/bin/trivalent --version
Trivalent 152.0.7977.82 Built from source for Fedora release 44 (Forty Four)   # exit 0
```
(`libexpat.so.1: no version information available` warnings are cosmetic --
nixpkgs expat is built without symbol versioning; Chromium tolerates it.)

**Decision: Branch B (`fedora-rpm`) is the default.** Revisit only if
nixpkgs-stable glibc reaches >= the Trivalent build's glibc, at which point
Branch A becomes viable and removes the extra RPM download.

---

## F5 -- sandbox call-path parity under buildFHSEnv

**Question:** does wrapping in `buildFHSEnv` change the renderer isolation path
vs running the binary unwrapped? (Spec definition: the isolation *syscalls* must
match on both sides.)

**Structural fact:** the Trivalent RPM ships **no `chrome-sandbox` setuid
helper** (`find . -name chrome-sandbox` -> nothing). There is therefore no
setuid path for `buildFHSEnv` to break; the only sandbox available is Chromium's
unprivileged user-namespace + seccomp-bpf. The vendor launcher
`usr/lib64/trivalent/trivalent.sh` additionally runs the browser inside its own
`bwrap --cap-drop ALL --dev-bind / /` jail. We run **that launcher unmodified**
as the FHS `runScript` (shebang kept as `#!/usr/bin/bash`, no strip, no lib64
move) so the jail is preserved -- quixaq's flake execs the raw binary and drops
it.

**Measurement** (`verify/30-sandbox-selfcheck.sh https://example.org`, strace
`-f -e trace=unshare,clone,clone3,setuid,setresuid,seccomp,prctl,execve`):

| | wrapped (buildFHSEnv -> trivalent.sh -> bwrap -> chromium) | unwrapped (raw `trivalent`) |
|---|---|---|
| `CLONE_NEWUSER` (unpriv userns) | yes | yes |
| `CLONE_NEWPID` / `CLONE_NEWNET` | yes / yes | yes / yes |
| seccomp-bpf filter installed | yes | yes |
| `execve(.../chrome-sandbox)` / `setuid(0)` | none | none |
| `--no-sandbox` / `--disable-setuid-sandbox` | none | none |
| real page rendered | yes (`example.org`, 266 text chars, exit 0) | yes |

`RESULT: wrapped and unwrapped agree on sandbox call path [netns,pidns,seccomp-bpf,userns]`

**Decision: `buildFHSEnv` running the unmodified vendor launcher is acceptable.**
The wrapper does not weaken the sandbox. `verify/30-sandbox-selfcheck.sh` is the
standing runtime gate for this and must pass after every version bump.

---

## aarch64

Same `pins.nix` / `lib/verify.nix` flow, `glibcStrategy = "fedora-rpm"` default
(`lib/mk-glibc-rpm.nix` carries the Fedora 44 `glibc-2.43-2.fc44.aarch64.rpm`).

**F4 -- confirmed on real aarch64** (2026-09-08, Trivalent
`152.0.7977.82-447136`). The `ci-aarch64` job on a native `ubuntu-24.04-arm`
runner: `installCheckPhase` resolves the full 73-object transitive closure and
the aarch64 binary `loaded + relocated + ran: Trivalent 152.0.7977.82` -- the
Fedora aarch64 glibc satisfies its `GLIBC_2.43` needs, same as x86_64.
`glibcStrategy = "fedora-rpm"` is correct for both arches. (A qemu-user
pre-check on omen15 agreed.)

**F5 -- renders a real page on aarch64** (2026-09-08, same version, on real
aarch64 hardware):

```
nix run github:hydroakri/trivalent-nix#trivalent -- --headless=new --disable-gpu \
  --virtual-time-budget=15000 --timeout=60000 --dump-dom https://example.org
-> full <!DOCTYPE html> ... <h1>Example Domain</h1> ... </html>
```

The FHS-wrapped browser launches, brings up the unprivileged user namespace, and
dumps the correct DOM over the network. The strace sandbox-parity table (as for
x86_64 above) is produced by `verify/30-sandbox-selfcheck.sh` -- an informational
step in `ci-aarch64` (`continue-on-error`; its `--dump-dom` budgets were raised
to 30 s virtual-time / 90 s timeout / 180 s wall-cap so a slow arm runner still
renders).
