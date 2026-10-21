#!/usr/bin/env python3
"""Build clean MacTV distribution files without user data or embedded signing secrets."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / "VERSION").read_text().strip()


def run(*args, cwd=ROOT):
    subprocess.run([str(arg) for arg in args], cwd=cwd, check=True)


def macos(output):
    with tempfile.TemporaryDirectory(prefix="mactv-package-") as folder:
        temp = Path(folder)
        derived = temp / "DerivedData"
        run("xcodebuild", "-project", ROOT / "MacTV_MacApp/MacTV_MacApp.xcodeproj",
            "-scheme", "MacTV_MacApp", "-configuration", "Release", "-derivedDataPath", derived,
            "ARCHS=arm64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGN_IDENTITY=-", "DEVELOPMENT_TEAM=",
            "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO", "COPY_PHASE_STRIP=YES",
            "OTHER_SWIFT_FLAGS=$(inherited) -file-prefix-map " + shlex.quote(str(ROOT) + "=/src/MacTV")
            + " -debug-prefix-map " + shlex.quote(str(ROOT) + "=/src/MacTV"), "build")
        stage = temp / "volume"
        stage.mkdir()
        app = stage / "MacTV.app"
        run("ditto", derived / "Build/Products/Release/MacTV.app", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
        (stage / "Read Me.txt").write_text(
            f"MacTV {VERSION}\n\n"
            "Drag MacTV into Applications. Requires macOS 14+ on Apple silicon.\n"
            "Install VLC 3 in /Applications/VLC.app for local video playback.\n\n"
            "This preview is ad-hoc signed and is not notarized. macOS Gatekeeper may block it.\n"
            "It does not include a Developer ID distribution certificate.\n"
            "Do not disable system security protections to install it.\n\n"
            "Open MacTV Settings to pair the Android remote and configure permissions.\n"
            "Streaming accounts, VLC and API keys are not included.\n\n"
            "Documentation: https://github.com/ayush-mangukia/MacTV\n")
        destination = output / f"MacTV-{VERSION}-macOS-arm64.dmg"
        if destination.exists():
            raise SystemExit(f"Output exists; choose an empty output directory: {destination}")
        run("hdiutil", "create", "-volname", f"MacTV {VERSION}", "-srcfolder", stage,
            "-format", "UDZO", "-fs", "HFS+", destination)
        run("hdiutil", "verify", destination)


def android(output):
    required = ["ANDROID_HOME", "MACTV_ANDROID_KEYSTORE", "MACTV_ANDROID_PASSWORD_FILE"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise SystemExit("Missing environment variables: " + ", ".join(missing))
    sdk = Path(os.environ["ANDROID_HOME"])
    tools = sorted((sdk / "build-tools").iterdir(), key=lambda p: tuple(int(x) for x in p.name.split(".") if x.isdigit()))[-1]
    project = ROOT / "MacTV_AndroidApp"
    run(project / "gradlew", ":app:assembleRelease", ":app:testDebugUnitTest", ":app:lintRelease", cwd=project)
    unsigned = project / "app/build/outputs/apk/release/app-release-unsigned.apk"
    if not unsigned.exists():
        raise SystemExit("Expected unsigned Release APK was not produced")
    destination = output / f"MacTV-Remote-{VERSION}-Android.apk"
    if destination.exists():
        raise SystemExit(f"Output exists; choose an empty output directory: {destination}")
    with tempfile.TemporaryDirectory(prefix="mactv-apk-") as folder:
        aligned = Path(folder) / "aligned.apk"
        run(tools / "zipalign", "-P", "16", "-f", "4", unsigned, aligned)
        password = "file:" + os.environ["MACTV_ANDROID_PASSWORD_FILE"]
        run(tools / "apksigner", "sign", "--ks", os.environ["MACTV_ANDROID_KEYSTORE"],
            "--ks-key-alias", os.environ.get("MACTV_ANDROID_KEY_ALIAS", "mactv"),
            "--ks-pass", password, "--out", destination, aligned)
        run(tools / "apksigner", "verify", "--verbose", destination)
        result = subprocess.check_output([str(tools / "aapt"), "dump", "badging", str(destination)], text=True)
        if "application-debuggable" in result or f"versionName='{VERSION}'" not in result:
            destination.unlink()
            raise SystemExit("Release APK manifest validation failed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", choices=["macos", "android", "all"], default="all")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    options = parser.parse_args()
    options.output.mkdir(parents=True, exist_ok=True)
    if options.platform in ("macos", "all"):
        macos(options.output)
    if options.platform in ("android", "all"):
        android(options.output)
