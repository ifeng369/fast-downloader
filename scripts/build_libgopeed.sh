#!/usr/bin/env bash
# 编译 libgopeed.aar（Gopeed Go 内核 → Android AAR）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOPEED_VERSION="${GOPEED_VERSION:-v1.9.3}"
# 默认只编 arm64（CI 只发布 arm64 包）；all_abis 模式通过 GOPEED_TARGETS 覆盖
GOPEED_TARGETS="${GOPEED_TARGETS:-android/arm64}"
AAR_OUT="${1:-${REPO_ROOT}/android/app/libs/libgopeed.aar}"

echo "==> GOPEED_VERSION=${GOPEED_VERSION}"
echo "==> GOPEED_TARGETS=${GOPEED_TARGETS}"

mkdir -p "$(dirname "${AAR_OUT}")"

if [ ! -d /tmp/gopeed-src ]; then
  echo "==> clone GopeedLab/gopeed ${GOPEED_VERSION}"
  git clone --depth 1 --branch "${GOPEED_VERSION}" \
    https://github.com/GopeedLab/gopeed.git /tmp/gopeed-src
else
  echo "==> reuse cached gopeed source"
fi

cd /tmp/gopeed-src

echo "==> install gomobile"
go install golang.org/x/mobile/cmd/gomobile@latest
go get golang.org/x/mobile/bind
export PATH="${PATH}:$(go env GOPATH)/bin"

echo "==> gomobile init"
gomobile init

echo "==> gomobile bind"
gomobile bind -tags nosqlite \
  -ldflags="-w -s -checklinkname=0" \
  -o "${AAR_OUT}" \
  -target="${GOPEED_TARGETS}" -androidapi 21 \
  -javapkg=com.gopeed \
  github.com/GopeedLab/gopeed/bind/mobile

echo "==> done: ${AAR_OUT}"
