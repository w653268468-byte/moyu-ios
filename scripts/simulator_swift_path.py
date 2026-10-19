"""Find the simulator-only WebKit Swift overlay workaround without changing iOS deployment support.

WebKit bug 293831: https://bugs.webkit.org/show_bug.cgi?id=293831#c2
The returned path is passed via SIMCTL_CHILD_DYLD_FALLBACK_LIBRARY_PATH only to test launches.
"""
import json
from pathlib import Path
import subprocess
import sys

device = sys.argv[1]
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))["devices"]
identifier = next(runtime for runtime, entries in devices.items() if any(entry["udid"] == device for entry in entries))
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
runtime = next(entry for entry in runtimes if entry["identifier"] == identifier)
folder = Path(runtime["bundlePath"]) / "Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift"
if folder.is_dir():
    print(folder)
