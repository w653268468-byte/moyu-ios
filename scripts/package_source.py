"""Create a source ZIP, excluding caches, credentials and generated build artifacts."""
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "dist/Moyu-iOS-source.zip"
OUTPUT.parent.mkdir(exist_ok=True)
folders = ["Sources", "Tests", "Resources", "Moyu.xcodeproj", ".github", "scripts", "docs", "Examples"]
files = [ROOT / name for name in ["README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "Package.swift", ".gitignore"]]
for folder in folders:
    files.extend(p for p in (ROOT / folder).rglob("*") if p.is_file() and "__pycache__" not in p.parts and "xcuserdata" not in p.parts)
with zipfile.ZipFile(OUTPUT, "w", zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(files):
        archive.write(path, Path("Moyu-iOS") / path.relative_to(ROOT))
with zipfile.ZipFile(OUTPUT) as archive:
    assert archive.testzip() is None
    assert "Moyu-iOS/.github/workflows/ios.yml" in archive.namelist()
    print(f"Created {OUTPUT}: {len(archive.namelist())} files, {OUTPUT.stat().st_size:,} bytes")
