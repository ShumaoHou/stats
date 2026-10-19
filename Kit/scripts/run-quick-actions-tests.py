#!/usr/bin/env python3
"""Run real Kit/AppKit layout tests with macOS Command Line Tools (no Xcode required).

Optional: --screenshots /path/to/output saves English/Chinese, light/dark renders.
Only test callbacks are clicked; no power settings, screen savers or helpers run.
"""
import argparse
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def lifecycle_source():
    # Use the real entry-point bodies, substituting only process/app/installer boundaries.
    block = runpy.run_path(str(ROOT / "Kit/scripts/run-smc-tests.py"))["swift_block"]
    restart = block((ROOT / "Kit/helpers.swift").read_text(), "public func restartApp(")
    restart = restart.replace("func restartApp(", "func testRestartApp(")
    restart = restart.replace("Process()", "ExitTestProcess()").replace("NSApp.terminate", "exitTestApplication.terminate")
    delegate = block((ROOT / "Stats/AppDelegate.swift").read_text(), "func applicationShouldTerminate(")
    delegate = delegate.replace("NSApplication", "ExitTestApplication")
    install = block((ROOT / "Kit/plugins/Updater.swift").read_text(), "public func install(path:")
    source = ("import Cocoa\n" + restart + "\nfinal class ExitTestDelegate {\n" + delegate +
              "\n}\nfinal class ExitTestUpdater: InstallerFixture {\n" + install + "\n}\n")
    source = source.replace("QuickActionsManager.shared", "exitTestManager!")
    return source.replace("showAlert(", "recordExitAlert(")


def run():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--screenshots", type=Path)
    args = parser.parse_args()
    env = dict(os.environ)
    if args.screenshots:
        args.screenshots.mkdir(parents=True, exist_ok=True)
        env["QUICK_ACTIONS_SCREENSHOTS"] = str(args.screenshots.resolve())

    with tempfile.TemporaryDirectory(prefix="stats-quick-actions-tests-") as directory:
        build = Path(directory)
        contents = build / "QuickActionsTests.app/Contents"
        binary = contents / "MacOS/QuickActionsTests"
        binary.parent.mkdir(parents=True)
        (build / "LifecycleUnderTest.swift").write_text(lifecycle_source())
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.stats.quick-actions-layout-tests",
            "CFBundleExecutable": binary.name,
            "CFBundlePackageType": "APPL",
            "CFBundleDevelopmentRegion": "en",
            "CFBundleLocalizations": ["en", "zh-Hans"],
            "LSUIElement": True,
        }))
        for language in ("en", "zh-Hans"):
            resource = Path(f"{language}.lproj/Localizable.strings")
            destination = contents / "Resources" / resource
            destination.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / "Stats/Supporting Files" / resource, destination)

        subprocess.run([
            "xcrun", "clang++", "-x", "objective-c++", "-fobjc-arc",
            "-I", str(ROOT / "Kit/lldb/include"), "-c", str(ROOT / "Kit/lldb/lldb.m"),
            "-o", str(build / "lldb.o"),
        ], check=True, timeout=60)
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5",
            "-module-cache-path", str(build / "cache"),
            "-I", str(ROOT / "Kit/lldb"), "-import-objc-header", str(ROOT / "Kit/Supporting Files/Kit.h"),
            *map(str, sorted((ROOT / "Kit").rglob("*.swift"))),
            str(ROOT / "SMC/smc.swift"), str(ROOT / "SMC/Helper/protocol.swift"),
            str(ROOT / "Tests/QuickActions.swift"), str(ROOT / "Tests/ClamshellSleep.swift"),
            str(ROOT / "Tests/QuickActionsLifecycle.swift"), str(build / "LifecycleUnderTest.swift"), str(build / "lldb.o"),
            "-L", str(ROOT / "Kit/lldb"), "-lleveldb", "-lc++", "-o", str(binary),
        ], check=True, timeout=240)
        for language in ("en", "zh-Hans"):
            subprocess.run([str(binary), "-AppleLanguages", f"({language})"],
                           check=True, env=env, timeout=60)


if __name__ == "__main__":
    run()
