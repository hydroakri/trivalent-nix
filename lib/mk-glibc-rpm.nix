# F4, Branch B: a glibc new enough for the Fedora-built Trivalent binary,
# unpacked straight from Fedora's own RPM.
#
# Why this exists: Trivalent is compiled in a `fedora:44` container (glibc 2.43).
# nixpkgs-unstable currently ships glibc 2.42, so the binary references
# `GLIBC_2.43` symbol versions that the nixpkgs loader cannot satisfy. Branch A
# (autoPatchelfHook against nixpkgs glibc) is still implemented in
# mk-trivalent.nix and MUST be run on the target before choosing between them --
# see ../F4-F5-RESULTS.md. This file is the fallback that pairs the vendor
# binary with a vendor loader.
#
# The version/hash below are pinned and updated by the same flow that updates
# the Trivalent RPM (they move far less often -- only when Fedora's base glibc
# minor changes). `nix build` fails closed on a hash mismatch.
{
  stdenvNoCC,
  fetchurl,
  rpm,
  cpio,
  lib,
  arch, # "x86_64" | "aarch64"
}:
let
  # Fedora 44 GA (frozen tree). GA build number is irrelevant to symbol
  # versions: 2.43-2 already provides the GLIBC_2.43 set.
  glibcVer = "2.43-2.fc44";
  urls = {
    x86_64 = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/x86_64/os/Packages/g/glibc-${glibcVer}.x86_64.rpm";
    aarch64 = "https://dl.fedoraproject.org/pub/fedora/linux/releases/44/Everything/aarch64/os/Packages/g/glibc-${glibcVer}.aarch64.rpm";
  };
  hashes = {
    # cross-checked against quixaq/trivalent-nix (independent third party) and
    # re-derived locally during the F4 test on omen15.
    x86_64 = "sha256-kN34GDK6UY+HaCZKaUTQsC4DCsx+eKou2QfX530KBp8=";
    aarch64 = "sha256-2hH8tKFtAItM9mlV/Ejlv2p/Q26DR9j0Q/gZNwnJgJg=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "fedora-glibc-for-trivalent";
  version = glibcVer;

  src = fetchurl {
    url = urls.${arch};
    hash = hashes.${arch};
  };

  nativeBuildInputs = [
    rpm
    cpio
  ];
  dontConfigure = true;
  dontBuild = true;
  dontPatchELF = true;
  dontStrip = true;

  unpackPhase = ''
    runHook preUnpack
    rpm2cpio "$src" | cpio -idm --quiet
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a usr "$out/"
    # normalise: some arches use lib64, some lib
    if [ -d "$out/usr/lib64" ] && [ ! -e "$out/usr/lib" ]; then
      ln -s lib64 "$out/usr/lib"
    fi
    test -e "$out/usr/lib64/ld-linux-x86-64.so.2" \
      || test -e "$out/usr/lib/ld-linux-aarch64.so.1" \
      || { echo "no dynamic loader found in glibc rpm"; exit 1; }
    runHook postInstall
  '';

  meta = {
    description = "Fedora ${glibcVer} glibc tree, loader + libs, for interpreter-patching the Trivalent RPM (F4 branch B)";
    license = lib.licenses.lgpl21Plus;
    platforms = [ "${arch}-linux" ];
  };
}
