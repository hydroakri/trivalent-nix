#!/usr/bin/env python3
"""Minimal repomd.xml / primary.xml reader.

No external deps. Operates on already-downloaded, already-decompressed files so
that transport + decompression + signature checks stay in the shell caller and
this file only parses XML.

Usage:
  repomd.py primary-location <repomd.xml>
      -> "<href>\\t<checksum-type>\\t<checksum>"   (href relative to repo baseurl)

  repomd.py find-package <primary.xml> <name> <arch>
      -> "<version>-<release>\\t<href>\\t<checksum-type>\\t<checksum>"
         for the highest version-release of <name> on <arch>.
      exit 3 if no such package.
"""
import sys
import xml.etree.ElementTree as ET

RPM_NS = "http://linux.duke.edu/metadata/rpm"
COMMON_NS = "http://linux.duke.edu/metadata/common"
REPO_NS = "http://linux.duke.edu/metadata/repo"


def _evr_key(epoch, ver, rel):
    def split(s):
        out, cur = [], ""
        isdig = None
        for ch in s:
            d = ch.isdigit()
            if isdig is None or d == isdig:
                cur += ch
            else:
                out.append(cur)
                cur = ch
            isdig = d
        if cur:
            out.append(cur)
        key = []
        for tok in out:
            if tok.isdigit():
                key.append((1, int(tok)))
            elif tok.isalpha():
                key.append((0, tok))
        return key

    return (int(epoch or 0), split(ver or ""), split(rel or ""))


def primary_location(path):
    root = ET.parse(path).getroot()
    for data in root.findall(f"{{{REPO_NS}}}data"):
        if data.get("type") == "primary":
            loc = data.find(f"{{{REPO_NS}}}location")
            csum = data.find(f"{{{REPO_NS}}}checksum")
            if loc is None or csum is None:
                sys.exit("primary entry missing location/checksum")
            print(f"{loc.get('href')}\t{csum.get('type')}\t{csum.text}")
            return
    sys.exit("no <data type=\"primary\"> in repomd.xml")


def find_package(path, name, arch):
    root = ET.parse(path).getroot()
    best = None
    for pkg in root.findall(f"{{{COMMON_NS}}}package"):
        if pkg.get("type") != "rpm":
            continue
        if (pkg.findtext(f"{{{COMMON_NS}}}name") or "") != name:
            continue
        if (pkg.findtext(f"{{{COMMON_NS}}}arch") or "") != arch:
            continue
        v = pkg.find(f"{{{COMMON_NS}}}version")
        loc = pkg.find(f"{{{COMMON_NS}}}location")
        csum = pkg.find(f"{{{COMMON_NS}}}checksum")
        if v is None or loc is None or csum is None:
            continue
        epoch, ver, rel = v.get("epoch"), v.get("ver"), v.get("rel")
        key = _evr_key(epoch, ver, rel)
        cand = (key, f"{ver}-{rel}", loc.get("href"), csum.get("type"), csum.text)
        if best is None or cand[0] > best[0]:
            best = cand
    if best is None:
        sys.exit(3)
    print(f"{best[1]}\t{best[2]}\t{best[3]}\t{best[4]}")


def main(argv):
    if len(argv) >= 3 and argv[1] == "primary-location":
        return primary_location(argv[2])
    if len(argv) >= 5 and argv[1] == "find-package":
        return find_package(argv[2], argv[3], argv[4])
    sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
