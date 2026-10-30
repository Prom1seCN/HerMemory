#!/usr/bin/env python3
"""Apply HerMemory's China download patches to a Hermes checkout's pm/ package.

Two independent, idempotent patches:

1. ``pm/artifact_mirror.py`` -- rewrite upstream release URLs onto npmmirror's
   binary CDN and prefer that mirror over hermes-assets. sha256 pins do not
   change: npmmirror serves the same bytes. Measured from a Chinese line:
   12.4 MB/s vs 103 KB/s.

2. ``pm/downloader.py`` -- resolve IPv4 first. A Chinese line blackholes IPv6
   to overseas CDNs, so every urllib attempt to hermes-assets sat in a 25 s
   TLS handshake (measured: IPv4 0.98 s, IPv6 25 s timeout).

Usage: patch_pm_mirror.py <checkout-dir>
"""
import pathlib
import sys

MARK_DOMESTIC = "DOMESTIC_FIRST"
MARK_IPV4 = "IPV4_FIRST"

HELPER = '''_NPMMIRROR = "https://registry.npmmirror.com/-/binary/"


def _domestic(url: str) -> str:
    """Rewrite upstream release URLs to the npmmirror binary CDN (China)."""
    import re as _re
    patterns = (
        (r"https://github\\.com/astral-sh/python-build-standalone/releases/download/([^/]+)/(.+)$", "python-build-standalone/"),
        (r"https://nodejs\\.org/dist/([^/]+)/(.+)$", "node/"),
        (r"https://unofficial-builds\\.nodejs\\.org/download/release/([^/]+)/(.+)$", "node/"),
    )
    for pattern, prefix in patterns:
        m = _re.match(pattern, url)
        if m:
            return _NPMMIRROR + prefix + m.group(1) + "/" + m.group(2)
    return url


'''

SHIM = '''from pm.network import edge_block, is_transient, retry_network

# IPV4_FIRST (HerMemory): prefer A records; IPv6 to overseas CDNs hangs.
_hermes_getaddrinfo = socket.getaddrinfo


def _ipv4_first_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    answers = _hermes_getaddrinfo(host, port, family, type, proto, flags)
    answers.sort(key=lambda answer: 0 if answer[0] == socket.AF_INET else 1)
    return answers


socket.getaddrinfo = _ipv4_first_getaddrinfo
'''

UPSTREAM_RETURN = "    return Source(url, dest, sha256, fallbacks=() if url == archive else (archive,))"
DOMESTIC_RETURN = ("    if url == archive:\n"
                   "        return Source(url, dest, sha256, fallbacks=())\n"
                   "    return Source(url, dest, sha256, fallbacks=(archive,))  # DOMESTIC_FIRST")
MIRROR_FIRST_RETURN = ("    if url == archive:\n"
                       "        return Source(url, dest, sha256, fallbacks=())\n"
                       "    return Source(archive, dest, sha256, fallbacks=(url,))  # MIRROR_FIRST")


def patch_artifact_mirror(root):
    path = root / "pm" / "artifact_mirror.py"
    if not path.is_file():
        return "skip: no pm/artifact_mirror.py"
    src = path.read_text(encoding="utf-8")
    if MARK_DOMESTIC in src:
        return "already patched"
    if "_domestic" not in src:
        if "def pinned_source(" not in src:
            return "skip: unexpected artifact_mirror.py layout"
        src = src.replace("def pinned_source(", HELPER + "def pinned_source(", 1)
    src = src.replace("    url = npm_registry_url(url, os.environ)",
                      "    url = _domestic(npm_registry_url(url, os.environ))", 1)
    if MIRROR_FIRST_RETURN in src:
        src = src.replace(MIRROR_FIRST_RETURN, DOMESTIC_RETURN, 1)
    elif UPSTREAM_RETURN in src:
        src = src.replace(UPSTREAM_RETURN, DOMESTIC_RETURN, 1)
    else:
        return "skip: unexpected pinned_source body"
    path.write_text(src, encoding="utf-8")
    return "patched"


def patch_downloader(root):
    path = root / "pm" / "downloader.py"
    if not path.is_file():
        return "skip: no pm/downloader.py"
    src = path.read_text(encoding="utf-8")
    if MARK_IPV4 in src:
        return "already patched"
    anchor = "from pm.network import edge_block, is_transient, retry_network"
    if anchor not in src:
        return "skip: unexpected downloader.py layout"
    src = src.replace(anchor, SHIM, 1)
    path.write_text(src, encoding="utf-8")
    return "patched"


def main():
    if len(sys.argv) != 2:
        print("usage: patch_pm_mirror.py <checkout-dir>", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1]).resolve()
    print("artifact_mirror.py:", patch_artifact_mirror(root))
    print("downloader.py:", patch_downloader(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
