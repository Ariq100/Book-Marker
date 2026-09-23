#!/usr/bin/env bash
# Cross-compiles deploycheck for Windows, macOS and Linux into ./dist.
# Pure Go, no cgo: every binary is a single self-contained file with no runtime dependencies.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
LDFLAGS="-s -w -X main.version=${VERSION}"
mkdir -p dist

go vet ./...
go test ./...

targets=(
  "windows amd64 deploycheck-windows-x64.exe"
  "windows arm64 deploycheck-windows-arm64.exe"
  "darwin  arm64 deploycheck-macos-apple-silicon"
  "darwin  amd64 deploycheck-macos-intel"
  "linux   amd64 deploycheck-linux-x64"
  "linux   arm64 deploycheck-linux-arm64"
)
for t in "${targets[@]}"; do
  read -r goos goarch out <<<"$t"
  CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" go build -trimpath -ldflags "$LDFLAGS" -o "dist/$out" .
  echo "built dist/$out"
done

# Checksums so downloaded binaries can be verified.
(cd dist && shasum -a 256 deploycheck-* > SHA256SUMS)
echo "wrote dist/SHA256SUMS"
