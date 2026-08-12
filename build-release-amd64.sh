#!/usr/bin/env bash
set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
plain='\033[0m'

XRAY_VERSION="${XUI_CUSTOM_XRAY_VERSION:-v26.6.27}"
OUT_DIR="${XUI_CUSTOM_RELEASE_DIR:-release}"
PACKAGE_NAME="${XUI_CUSTOM_PACKAGE_NAME:-x-ui-linux-amd64.tar.gz}"

log() {
    echo -e "${green}$*${plain}"
}

fail() {
    echo -e "${red}$*${plain}" >&2
    exit 1
}

command -v go > /dev/null 2>&1 || fail "go is required. Install Go 1.26.5 first."
command -v npm > /dev/null 2>&1 || fail "npm is required. Install Node.js 24 first."
command -v curl > /dev/null 2>&1 || fail "curl is required."
command -v unzip > /dev/null 2>&1 || fail "unzip is required."

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${ROOT_DIR}/x-ui"
BIN_DIR="${BUILD_DIR}/bin"

log "Building frontend..."
cd "${ROOT_DIR}/frontend"
npm install
npm run build

log "Building backend..."
cd "${ROOT_DIR}"
go build -ldflags "-w -s" -o xui-release main.go

log "Preparing package directory..."
rm -rf "${BUILD_DIR}"
mkdir -p "${BIN_DIR}" "${OUT_DIR}"
cp xui-release "${BUILD_DIR}/x-ui"
cp x-ui.sh "${BUILD_DIR}/x-ui.sh"
cp x-ui.service.debian "${BUILD_DIR}/x-ui.service.debian"
cp x-ui.service.rhel "${BUILD_DIR}/x-ui.service.rhel"
cp x-ui.service.arch "${BUILD_DIR}/x-ui.service.arch"
chmod +x "${BUILD_DIR}/x-ui" "${BUILD_DIR}/x-ui.sh"

log "Downloading Xray-core ${XRAY_VERSION}..."
cd "${BIN_DIR}"
curl -fL -o Xray-linux-64.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
unzip -o Xray-linux-64.zip
rm -f Xray-linux-64.zip
mv -f xray xray-linux-amd64
chmod +x xray-linux-amd64

log "Creating ${OUT_DIR}/${PACKAGE_NAME}..."
cd "${ROOT_DIR}"
tar -czf "${OUT_DIR}/${PACKAGE_NAME}" x-ui
rm -f xui-release

log "Done: ${OUT_DIR}/${PACKAGE_NAME}"
