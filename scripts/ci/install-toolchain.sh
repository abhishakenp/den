#!/bin/zsh
# Installs a swift.org toolchain (with the Embedded Swift stdlib cordis-build needs) without sudo,
# by expanding the official .pkg's payload into a plain directory.
#   scripts/ci/install-toolchain.sh <version> <dest.xctoolchain>
#   SWIFT_PKG_URL overrides the download (e.g. file:///path/to/swift.pkg).
# Skips the download when <dest> already has swiftc and usr/lib/swift/embedded (cache hit).
set -euo pipefail
version=${1:?version, e.g. 6.3.2} dest=${2:?destination directory}
if [[ -x $dest/usr/bin/swiftc && -d $dest/usr/lib/swift/embedded ]]; then
  echo "toolchain already at $dest"
else
  url=${SWIFT_PKG_URL:-https://download.swift.org/swift-$version-release/xcode/swift-$version-RELEASE/swift-$version-RELEASE-osx.pkg}
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  echo "downloading $url"
  curl -fsSL --retry 3 -o "$tmp/swift.pkg" "$url"
  pkgutil --check-signature "$tmp/swift.pkg"
  pkgutil --expand-full "$tmp/swift.pkg" "$tmp/x"
  payload=("$tmp"/x/*.pkg/Payload(N))
  (( ${#payload} == 1 )) || { echo "unexpected pkg layout"; ls "$tmp/x"; exit 1; }
  rm -rf "$dest"
  mkdir -p "${dest:h}"
  mv "$payload[1]" "$dest"
fi
[[ -d $dest/usr/lib/swift/embedded ]] || { echo "no embedded stdlib in $dest"; exit 1; }
"$dest/usr/bin/swiftc" --version
