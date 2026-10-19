"""Normalized Git blob hashes for all distributable project files."""
from pathlib import Path
import hashlib
import json
import sys

ROOT = Path(__file__).resolve().parents[1]
FOLDERS = ["Sources", "Tests", "Resources", "Moyu.xcodeproj", ".github", "scripts", "docs", "Examples", "Vendor"]
TOP_LEVEL = ["README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "Package.swift", ".gitignore"]


def files():
    result = [ROOT / name for name in TOP_LEVEL]
    for folder in FOLDERS:
        result.extend(path for path in (ROOT / folder).rglob("*") if path.is_file() and not {"__pycache__", "xcuserdata", ".build", ".git", ".swiftpm"}.intersection(path.parts))
    return sorted(result)


def normalized(path):
    try:
        return path.read_text(encoding="utf-8").encode("utf-8")
    except UnicodeDecodeError:
        return path.read_bytes()


def manifest():
    result = {}
    for path in files():
        content = normalized(path)
        result[path.relative_to(ROOT).as_posix()] = hashlib.sha1(b"blob " + str(len(content)).encode() + b"\0" + content).hexdigest()
    return result


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if sys.argv[1:2] == ["--entries"]:
        entries = []
        for name in sys.argv[2:]:
            path = (ROOT / name).resolve()
            relative = path.relative_to(ROOT).as_posix()
            entries.append(dict(path=relative, mode="100644", type="blob", content=path.read_text(encoding="utf-8")))
        print(json.dumps(entries, ensure_ascii=False))
    else:
        print(json.dumps(manifest()))
