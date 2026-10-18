"""Cross-platform structural checks. This does NOT replace Swift/Xcode compilation."""
from pathlib import Path
import json
import plistlib
import re
import struct
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
project = (ROOT / "Moyu.xcodeproj/project.pbxproj").read_text(encoding="utf-8")


def parse_openstep(text):
    tokens = re.findall(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}(),;=]|[^\s{}(),;=]+', text)
    tokens = [t for t in tokens if not t.startswith(("//", "/*"))]
    position = 0

    def take(expected=None):
        nonlocal position
        assert position < len(tokens), "Unexpected end of PBX project"
        token = tokens[position]
        position += 1
        assert expected is None or token == expected, f"Expected {expected}, got {token}"
        return token

    def value():
        token = take()
        if token == "{":
            result = {}
            while tokens[position] != "}":
                key = take()
                take("=")
                assert key not in result, f"Duplicate key {key}"
                result[key] = value()
                take(";")
            take("}")
            return result
        if token == "(":
            result = []
            while tokens[position] != ")":
                result.append(value())
                if tokens[position] != ")": take(",")
            take(")")
            return result
        assert token not in "}),;=", f"Invalid value {token}"
        return json.loads(token) if token.startswith('"') else token

    result = value()
    assert position == len(tokens), "Trailing PBX project content"
    return result


parsed = parse_openstep(project)
assert parsed["objects"][parsed["rootObject"]]["isa"] == "PBXProject"
objects = re.findall(r"^\s*([A-F0-9]{24}) = \{", project, re.M)
assert len(objects) == len(set(objects)), "Duplicate PBX object identifiers"
references = set(re.findall(r"\b[A-F0-9]{24}\b", project))
assert references == set(objects), "Unresolved PBX reference"
for source in (ROOT / "Sources").rglob("*.swift"):
    assert source.relative_to(ROOT).as_posix() in project, f"Missing Xcode source: {source}"
    text = source.read_text(encoding="utf-8")
    assert "<<<<<<<" not in text and ">>>>>>>" not in text, f"Conflict markers: {source}"
for path in re.findall(r'path = "([^"]+)"; sourceTree = SOURCE_ROOT;', project):
    assert (ROOT / path).exists(), f"Missing project file: {path}"
for path in ["Resources/Info.plist", "Resources/PrivacyInfo.xcprivacy"]:
    with (ROOT / path).open("rb") as handle: plistlib.load(handle)
ET.parse(ROOT / "Moyu.xcodeproj/xcshareddata/xcschemes/Moyu.xcscheme")
for path in (ROOT / "Resources/Assets.xcassets").rglob("Contents.json"):
    data = json.loads(path.read_text(encoding="utf-8"))
    for image in data.get("images", []): assert (path.parent / image["filename"]).exists()
icon = (ROOT / "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png").read_bytes()
assert icon[:8] == b"\x89PNG\r\n\x1a\n"
assert struct.unpack(">II", icon[16:24]) == (1024, 1024)
assert icon[25] == 2, "App icon must have no alpha channel"
assert 'version = 2.7.7;' in project and 'exact: "2.7.7"' in (ROOT / "Package.swift").read_text()
sample = json.loads((ROOT / "Examples/booksource.example.json").read_text(encoding="utf-8"))
assert sample["ruleToc"]["chapterList"] and sample["ruleContent"]["content"]
print(f"PASS: {len(objects)} PBX objects, all source/resource references, plist/scheme XML, icon, dependency pin and example JSON")
print("Swift unit tests, SwiftUI type checking and IPA generation require the macOS CI job.")
