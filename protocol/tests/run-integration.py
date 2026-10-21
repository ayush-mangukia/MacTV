#!/usr/bin/env python3
"""Run isolated transport integration tests. Requires Xcode, the Android SDK and JDK 25."""
import argparse
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android', metavar='SERIAL', help='Install and run transport tests on this Android device')
    parser.add_argument('--host', default='127.0.0.1', help='Mac address reachable by the test client (emulator: 10.0.2.2)')
    parser.add_argument('--discovery', action='store_true', help='Also verify multicast discovery on a real shared LAN')
    args = parser.parse_args()
    if args.discovery and not args.android:
        parser.error('--discovery requires --android SERIAL')
    repo = Path(__file__).resolve().parents[2]
    env = os.environ.copy()
    if 'DEVELOPER_DIR' not in env and Path('/Applications/Xcode.app/Contents/Developer').exists():
        env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    bundled_java = Path('/Applications/Android Studio Preview.app/Contents/jbr/Contents/Home')
    if 'JAVA_HOME' not in env and bundled_java.exists():
        env['JAVA_HOME'] = str(bundled_java)
    sdk = Path(env.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk')))
    env['ANDROID_HOME'] = str(sdk)
    android = repo / 'MacTV_AndroidApp'
    def run(command, **kwargs):
        return subprocess.run(list(map(str, command)), env=env, check=True, **kwargs)
    with tempfile.TemporaryDirectory(prefix='mactv-transport-') as temp:
        temp = Path(temp)
        executable = temp / 'receiver'
        sources = repo / 'MacTV_MacApp/MacTV_MacApp'
        run(['xcrun', 'swiftc', sources/'RemoteWire.swift', sources/'RemoteServer.swift',
             repo/'protocol/tests/ServerHarness.swift', '-o', executable])
        if args.android:
            run(['./gradlew', ':app:assembleDebug', ':app:assembleDebugAndroidTest'], cwd=android)
            adb = [str(sdk/'platform-tools/adb'), '-s', args.android]
            for apk in ['debug/app-debug.apk', 'androidTest/debug/app-debug-androidTest.apk']:
                run(adb + ['install', '-r', str(android/'app/build/outputs/apk'/apk)])
            api = subprocess.check_output(adb + ['shell','getprop','ro.build.version.sdk'],text=True).strip()
            if int(api) >= 37:
                run(adb + ['shell','pm','grant','com.example.mactv_androidapp','android.permission.ACCESS_LOCAL_NETWORK'])
        invitation = temp / 'invitation'
        with (temp/'receiver.log').open('w') as log:
            receiver = subprocess.Popen([str(executable),str(invitation),args.host],env=env,stdout=log,stderr=log)
            try:
                for _ in range(100):
                    if invitation.exists():
                        break
                    if receiver.poll() is not None:
                        raise RuntimeError('Receiver exited. Check that test port 8766 is free.')
                    time.sleep(.1)
                if not invitation.exists():
                    raise RuntimeError('Receiver did not start')
                if args.android:
                    classes = 'com.example.mactv_androidapp.TransportIntegrationTest'
                    if args.discovery:
                        classes += ',com.example.mactv_androidapp.DiscoveryIntegrationTest'
                    result = subprocess.run(adb + ['shell','am','instrument','-w','-r','-e','class',
                        classes,'-e','invitation',invitation.read_text(),
                        'com.example.mactv_androidapp.test/androidx.test.runner.AndroidJUnitRunner'],
                        env=env,capture_output=True,text=True,timeout=100)
                    print(result.stdout + result.stderr)
                    if result.returncode or not re.search(r'OK \(\d+ tests?\)', result.stdout):
                        raise RuntimeError('Android integration failed; see the individual test results above')
                else:
                    env['MAC_TV_TEST_INVITATION'] = str(invitation)
                    run(['./gradlew',':app:testDebugUnitTest','--tests',
                         'com.example.mactv_androidapp.ServerProtocolTest','--rerun-tasks'],cwd=android)
            except Exception:
                log.flush()
                print((temp/'receiver.log').read_text())
                raise
            finally:
                receiver.terminate()
                receiver.wait(timeout=5)


if __name__ == '__main__':
    main()
