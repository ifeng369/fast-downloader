#!/usr/bin/env bash
# 编译 libgopeed.aar（Gopeed Go 内核 → Android AAR）
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GOPEED_VERSION="${GOPEED_VERSION:-v1.9.3}"
# 默认只编 arm64（CI 只发布 arm64 包）；all_abis 模式通过 GOPEED_TARGETS 覆盖
GOPEED_TARGETS="${GOPEED_TARGETS:-android/arm64}"
# 钉版本：@latest 曾在 2026-11 漂到需要 Go 1.26，直接让 CI 挂掉
GOMOBILE_VERSION="${GOMOBILE_VERSION:-v0.0.0-20261117202452-47699113848a}"
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

echo "==> install gomobile ${GOMOBILE_VERSION}"
go install "golang.org/x/mobile/cmd/gomobile@${GOMOBILE_VERSION}"
go get "golang.org/x/mobile/bind@${GOMOBILE_VERSION}"
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
