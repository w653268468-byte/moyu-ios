"""Generate the checked-in Xcode project and original icon, using only Python stdlib."""
from pathlib import Path
import hashlib
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


def generate_project():
    sources = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Sources").rglob("*.swift"))
    resources = ["Resources/Assets.xcassets", "Resources/PrivacyInfo.xcprivacy"]
    objects = []

    def obj(name, body):
        objects.append(f"\t\t{uid(name)} = {{ {body} }};")

    def ids(names):
        return "(" + ", ".join(uid(n) for n in names) + ",)"

    for path in sources + resources:
        filetype = "sourcecode.swift" if path.endswith(".swift") else ("folder.assetcatalog" if path.endswith(".xcassets") else "text.xml")
        obj("file:" + path, f"isa = PBXFileReference; lastKnownFileType = {filetype}; path = {quote(path)}; sourceTree = SOURCE_ROOT;")
        obj("build:" + path, f"isa = PBXBuildFile; fileRef = {uid('file:' + path)};")

    obj("product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Gavin.app; sourceTree = BUILT_PRODUCTS_DIR;')
    obj("products", f'isa = PBXGroup; children = {ids(["product"])}; name = Products; sourceTree = "<group>";')
    obj("main", f'isa = PBXGroup; children = {ids(["file:" + p for p in sources + resources] + ["products"])}; sourceTree = "<group>";')
    obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["build:" + p for p in sources])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("resources", f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {ids(["build:" + p for p in resources])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("soup-build", f'isa = PBXBuildFile; productRef = {uid("soup-product")};')
    obj("frameworks", f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {ids(["soup-build", "zip-build"])}; runOnlyForDeploymentPostprocessing = 0;')
    obj("soup-package", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/scinfu/SwiftSoup.git"; requirement = { kind = exactVersion; version = 2.7.7; };')
    obj("zip-build", f'isa = PBXBuildFile; productRef = {uid("zip-product")};')
    obj("zip-package", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/weichsel/ZIPFoundation.git"; requirement = { kind = exactVersion; version = 0.9.19; };')
    obj("zip-product", f'isa = XCSwiftPackageProductDependency; package = {uid("zip-package")}; productName = ZIPFoundation;')
    obj("soup-product", f'isa = XCSwiftPackageProductDependency; package = {uid("soup-package")}; productName = SwiftSoup;')

    common = {
        "CLANG_ENABLE_MODULES": "YES", "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
        "SWIFT_VERSION": "5.0", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    }
    app = {
        "PRODUCT_NAME": "Gavin", "PRODUCT_BUNDLE_IDENTIFIER": "org.moyu.reader",
        "INFOPLIST_FILE": "Resources/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon", "CODE_SIGN_STYLE": "Automatic",
        "TARGETED_DEVICE_FAMILY": "1,2", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SUPPORTS_MACCATALYST": "NO", "CURRENT_PROJECT_VERSION": "2", "MARKETING_VERSION": "2.0.0",
        "SWIFT_EMIT_LOC_STRINGS": "YES", "ENABLE_PREVIEWS": "YES",
    }
    for config in ["Debug", "Release"]:
        for scope, settings in [("project", common), ("app", app)]:
            settings = dict(settings)
            if scope == "project":
                settings["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if config == "Debug" else "-O"
                settings["DEBUG_INFORMATION_FORMAT"] = "dwarf" if config == "Debug" else "dwarf-with-dsym"
                if config == "Debug": settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            body = " ".join(f"{k} = {quote(v)};" for k, v in settings.items())
            obj(f"{scope}-{config}", f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {config};')
    for scope in ["project", "app"]:
        obj(scope + "-config", f'isa = XCConfigurationList; buildConfigurations = {ids([scope + "-Debug", scope + "-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

    obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {uid("app-config")}; buildPhases = {ids(["sources", "frameworks", "resources"])}; buildRules = (); dependencies = (); name = Moyu; packageProductDependencies = {ids(["soup-product", "zip-product"])}; productName = Gavin; productReference = {uid("product")}; productType = "com.apple.product-type.application";')
    obj("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{ {uid("target")} = {{ CreatedOnToolsVersion = 16.0; }}; }}; }}; buildConfigurationList = {uid("project-config")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh-Hans; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base,); mainGroup = {uid("main")}; packageReferences = {ids(["soup-package", "zip-package"])}; productRefGroup = {uid("products")}; projectDirPath = ""; projectRoot = ""; targets = {ids(["target"])};')
    folder = ROOT / "Moyu.xcodeproj"
    folder.mkdir(exist_ok=True)
    (folder / "project.pbxproj").write_text("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {uid('project')};\n}}\n", encoding="utf-8")
    schemes = folder / "xcshareddata/xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Gavin.app" BlueprintName="Moyu" ReferencedContainer="container:Moyu.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (schemes / "Moyu.xcscheme").write_text(scheme, encoding="utf-8")


def generate_icon():
    width = 1024
    rows = [bytearray(width * 3) for _ in range(width)]
    for y, row in enumerate(rows):
        for x in range(width):
            t = (x + y) / (2 * width)
            row[x * 3:x * 3 + 3] = bytes((int(26 + 18 * t), int(65 + 30 * t), int(58 + 21 * t)))

    def polygon(points, color):
        for y in range(max(0, min(p[1] for p in points)), min(width, max(p[1] for p in points) + 1)):
            crosses = []
            for a, b in zip(points, points[1:] + points[:1]):
                if min(a[1], b[1]) <= y < max(a[1], b[1]):
                    crosses.append(int(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1])))
            crosses.sort()
            for left, right in zip(crosses[::2], crosses[1::2]):
                for x in range(max(0, left), min(width, right + 1)):
                    rows[y][x * 3:x * 3 + 3] = bytes(color)

    polygon([(180, 320), (370, 300), (512, 354), (512, 782), (355, 728), (180, 748)], (216, 219, 201))
    polygon([(512, 354), (662, 300), (844, 320), (844, 748), (670, 728), (512, 782)], (245, 239, 219))
    polygon([(512, 354), (526, 350), (526, 777), (512, 782)], (187, 195, 176))
    polygon([(681, 305), (749, 310), (749, 507), (714, 472), (681, 507)], (204, 141, 106))
    polygon([(232, 416), (429, 437), (429, 450), (232, 429)], (166, 180, 161))
    polygon([(232, 481), (429, 502), (429, 515), (232, 494)], (166, 180, 161))
    polygon([(232, 546), (382, 563), (382, 576), (232, 559)], (166, 180, 161))
    raw = b"".join(b"\0" + row for row in rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, width, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    assets = ROOT / "Resources/Assets.xcassets"
    icon = assets / "AppIcon.appiconset"
    icon.mkdir(parents=True, exist_ok=True)
    (assets / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}), encoding="utf-8")
    (icon / "AppIcon.png").write_bytes(png)
    (icon / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")


if __name__ == "__main__":
    generate_project()
    generate_icon()
    print("Generated Moyu.xcodeproj and AppIcon.png")
