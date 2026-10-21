#!/bin/sh
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
FFMPEG=$(command -v ffmpeg || true)
if [ -z "$FFMPEG" ] && [ -x /opt/homebrew/bin/ffmpeg ]; then FFMPEG=/opt/homebrew/bin/ffmpeg; fi
if [ -z "$FFMPEG" ]; then echo 'ffmpeg is needed only to generate the test fixture.' >&2; exit 1; fi
"$FFMPEG" -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24 -t 35 -c:v libx264 -preset ultrafast "$TASK_TMP/fixture.mp4"
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  "$REPO/MacTV_MacApp/MacTV_MacApp/VLCBackend.swift" \
  "$REPO/MacTV_MacApp/MacTV_MacApp/MovieLibrary.swift" \
  "$REPO/MacTV_MacApp/Tests/LocalMovieTests.swift" \
  -Xlinker -rpath -Xlinker /Applications/VLC.app/Contents/MacOS/lib -o "$TASK_TMP/movie-tests"
if [ "$#" -gt 0 ]; then "$TASK_TMP/movie-tests" "$TASK_TMP/fixture.mp4" "$1"; else "$TASK_TMP/movie-tests" "$TASK_TMP/fixture.mp4"; fi

# Compile the real application views/model; the test supplies its own entry point.
python3 - "$REPO" "$TASK_TMP" <<'PYTEST'
import pathlib, subprocess, sys
repo=pathlib.Path(sys.argv[1]); temp=pathlib.Path(sys.argv[2])
sources=sorted(str(p) for p in (repo/'MacTV_MacApp/MacTV_MacApp').glob('*.swift') if p.name != 'MyApp.swift')
subprocess.run(['xcrun','swiftc','-swift-version','5','-default-isolation','MainActor',*sources,
    str(repo/'MacTV_MacApp/Tests/MovieControlsTests.swift'),'-Xlinker','-rpath','-Xlinker',
    '/Applications/VLC.app/Contents/MacOS/lib','-o',str(temp/'controls-tests')],check=True)
subprocess.run([str(temp/'controls-tests'),str(temp/'fixture.mp4')],check=True)
PYTEST
