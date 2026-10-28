#!/bin/bash
# Download the official AptaSuite release next to this script and check its checksum.
# Run once on a Nova login node after cloning:  ./install.sh
set -euo pipefail

VERSION=0.9.8
SHA256=aa940f239d19f7c803924a45008f3faa5936af8ef391930d2e6ad3ca2f27ab90
URL=https://github.com/drivenbyentropy/aptasuite/releases/download/v$VERSION/aptasuite-$VERSION.zip

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
JAR=$HERE/aptasuite-$VERSION/aptasuite-$VERSION.jar

if [ -f "$JAR" ]; then
    echo "AptaSuite $VERSION is already installed: $JAR"
    exit 0
fi
if [ -e "$HERE/aptasuite-$VERSION" ]; then
    echo "$HERE/aptasuite-$VERSION exists but has no jar (incomplete install?); move it aside and re-run." >&2
    exit 1
fi

# Download and unpack in a temporary folder, then move into place in one step,
# so an interrupted install never leaves a half-unpacked copy behind.
TMP=$(mktemp -d "$HERE/.install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

echo "Downloading AptaSuite $VERSION (345 MB) from the official GitHub release..."
curl -sS -L --fail -o "$TMP/aptasuite.zip" "$URL"
echo "$SHA256  $TMP/aptasuite.zip" | sha256sum -c --quiet -
unzip -q "$TMP/aptasuite.zip" -d "$TMP"
mv "$TMP/aptasuite-$VERSION" "$HERE/"

echo "Installed: $JAR"
echo "Next: sbatch $HERE/test/smoke_test.sbatch   (about 10 minutes; prints PASS or FAIL)"
