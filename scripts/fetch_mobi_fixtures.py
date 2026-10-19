"""Pinned upstream test inputs, downloaded only in CI and never bundled or redistributed."""
from pathlib import Path
import hashlib
import urllib.request

commit = "906274205c11944b628da1c553b255acb1af7c55"
checksums = {
    "sample-cp1252.mobi": "e77aa8f99d65f12bc7b5d71f272a2a4a8f36fe6d5c00e9b95c8a926b145ad088",
    "sample-ncx.mobi": "bb33217f3369d8ca6c5a373ca8e21a151be5494f5de6623aa9e7f42fb5fed743",
    "sample-unicode-huffdic.mobi": "560dda58429878a64f73381ffddfcf1a59809e7c669a5222666257df8976a68f",
    "sample-unicode-uncompressed.mobi": "9419834c41bf2e7e9ccb78a870e679d56dc4a0a380c5afae3168a2fb5827412d",
    "sample-obfuscated-fonts.mobi": "34fc67043eeeaa6563481d6ea2fea1b5349cb73e459a1f10e3aa09186f56302e",
}
folder = Path("build/mobi-fixtures")
folder.mkdir(parents=True, exist_ok=True)
for name, digest in checksums.items():
    url = f"https://raw.githubusercontent.com/bfabiszewski/libmobi/{commit}/tests/samples/{name}"
    with urllib.request.urlopen(url, timeout=30) as response:
        data = response.read(2 * 1024 * 1024)
    assert hashlib.sha256(data).hexdigest() == digest, name
    (folder / name).write_bytes(data)
    print(f"Verified {name}: {len(data):,} bytes")
