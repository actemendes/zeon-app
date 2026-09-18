#!/usr/bin/env python3
"""Implementation of canonical iOS lab build actions; never installs or provisions."""
import argparse
import hashlib
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(args, timeout=1200):
    subprocess.run(args, cwd=ROOT, check=True, timeout=timeout)


def tree_hash(path):
    digest = hashlib.sha256()
    for item in sorted(path.rglob('*')):
        if item.is_symlink():
            digest.update(item.relative_to(path).as_posix().encode() + b'\0link\0')
            digest.update(os.readlink(item).encode())
        elif item.is_file():
            digest.update(item.relative_to(path).as_posix().encode() + b'\0file\0')
            content = hashlib.sha256()
            with item.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    content.update(block)
            digest.update(content.digest())
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['ios-test-simulator', 'ios-test-runner', 'ios-test-diagnostic'])
    parser.add_argument('--simulator', action='store_true', help='Compile XCTest runner unsigned for Simulator')
    parser.add_argument('--development', action='store_true', help='Allow dirty source; never acceptance evidence')
    args = parser.parse_args()
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT))
    if dirty and not args.development:
        parser.error('Lab acceptance artifacts require a committed clean source candidate')
    run(['xcodebuild', '-version'], 180)
    run(['xcodebuild', '-checkFirstLaunchStatus'], 60)
    run(['flutter', 'pub', 'get', '--enforce-lockfile'], 180)
    run(['dart', 'run', 'slang'], 180)
    kind = ('simulator' if args.action == 'ios-test-simulator' else 'diagnostic' if args.action == 'ios-test-diagnostic'
            else 'runner-simulator' if args.simulator else 'runner-device')
    with tempfile.TemporaryDirectory(prefix='zeon-ios-build-') as scratch:
        scratch = Path(scratch)
        if kind == 'simulator':
            derived = ROOT / 'build/ios/lab-simulator'
            run(['flutter', 'build', 'ios', '--simulator', '--debug', '--no-codesign', '--no-pub',
                 '--config-only', '--target', 'integration_test/ios_ui_test.dart'])
            run(['xcodebuild', '-quiet', '-workspace', 'ios/Runner.xcworkspace', '-scheme', 'Runner',
                 '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                 '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', str(derived),
                 'CODE_SIGNING_ALLOWED=NO',
                 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG ZEON_IOS_SIMULATOR_LAB', 'build'])
            source = derived / 'Build/Products/Debug-iphonesimulator/Runner.app'
        elif kind == 'diagnostic':
            run(['flutter', 'build', 'ios', '--profile', '--config-only', '--no-pub', '--target', 'lib/main.dart'])
            run(['xcodebuild', '-workspace', 'ios/Runner.xcworkspace', '-scheme', 'Runner',
                 '-configuration', 'Profile', '-destination', 'generic/platform=iOS',
                 '-derivedDataPath', str(scratch / 'derived'),
                 'ZEON_IOS_LAB_SOURCE_SHA=' + sha,
                 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) ZEON_IOS_LAB', 'build'])
            source = scratch / 'derived/Build/Products/Profile-iphoneos/Runner.app'
        else:
            # This identifier/profile must already exist locally. Never request
            # Apple registration, change product signing, or reuse an extension ID.
            if kind == 'runner-device':
                required = ['ZEON_LAB_RUNNER_BUNDLE_ID', 'ZEON_LAB_RUNNER_PROFILE', 'ZEON_LAB_DEVELOPMENT_TEAM']
                if any(not os.environ.get(key) for key in required):
                    parser.error('BLOCKED: existing dedicated runner development signing is required: ' + ', '.join(required))
            run(['ruby', str(ROOT / 'scripts/apple/ios_lab_project.rb'), str(scratch)], 60)
            command = ['xcodebuild', '-project', str(scratch / 'IosLab.xcodeproj'),
                       '-scheme', 'IosLab', '-configuration', 'Debug', '-derivedDataPath', str(scratch / 'derived'),
                       '-destination', 'generic/platform=iOS Simulator' if args.simulator else 'generic/platform=iOS',
                       'build-for-testing']
            if args.simulator:
                command.append('CODE_SIGNING_ALLOWED=NO')
            run(command)
            source = scratch / 'derived/Build/Products'
        artifact_hash = tree_hash(source)
        if not args.development and subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT):
            parser.error('Build changed tracked source or lockfiles; commit the resolved candidate before publishing')
        destination = ROOT / 'out/installers/ios/lab' / sha / (kind + '-' + artifact_hash[:12])
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists():
            destination.mkdir()
            shutil.copytree(source, destination / ('Runner.app' if kind in ('simulator', 'diagnostic') else 'Products'), symlinks=True)
            manifest = {'schema': 1, 'source_sha': sha, 'source_dirty': dirty, 'kind': kind,
                        'artifact_sha256': artifact_hash, 'hash_algorithm': 'path-type-content-v1',
                        'evidence_kind': 'UI_LOGIC_ONLY' if kind == 'simulator' else 'DEVICE_TEST_RUNNER',
                        'entrypoint': 'scripts/build.sh', 'core_sha256': tree_hash(ROOT / 'ios/Frameworks/HiddifyCore.xcframework')}
            flutter = json.loads(subprocess.check_output(['flutter', '--version', '--machine'], cwd=ROOT))
            manifest['tools'] = {key: flutter[key] for key in ['frameworkVersion', 'frameworkRevision', 'dartSdkVersion']}
            manifest['tools'].update({
                'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
                'go': subprocess.check_output(['go', 'version'], text=True).strip(),
                'cocoapods': subprocess.check_output(['pod', '--version'], text=True).strip(),
            })
            framework = plistlib.loads((ROOT / 'ios/Frameworks/HiddifyCore.xcframework/Info.plist').read_bytes())
            manifest['core_slices'] = [{key: entry[key] for key in
                ['LibraryIdentifier', 'SupportedArchitectures', 'SupportedPlatform']} for entry in framework['AvailableLibraries']]
            manifest['flags'] = {'simulator_native_vpn_disabled': kind == 'simulator',
                                 'diagnostic_lease': kind == 'diagnostic', 'automatic_provisioning': False}
            (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
        print(destination)


if __name__ == '__main__':
    main()
