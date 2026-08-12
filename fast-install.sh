#!/usr/bin/env bash
set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

RELEASE_TAG="${XUI_CUSTOM_RELEASE_TAG:-v3xui-custom}"
PACKAGE_NAME="${XUI_CUSTOM_PACKAGE_NAME:-x-ui-linux-amd64.tar.gz}"
PACKAGE_URL="${XUI_CUSTOM_PACKAGE_URL:-https://github.com/zbl12312/3xui-api-/releases/download/${RELEASE_TAG}/${PACKAGE_NAME}}"
INSTALL_DIR="${XUI_CUSTOM_INSTALL_DIR:-/usr/local/x-ui}"
SERVICE_DIR="${XUI_CUSTOM_SERVICE_DIR:-/etc/systemd/system}"

log() {
    echo -e "${green}$*${plain}"
}

warn() {
    echo -e "${yellow}$*${plain}"
}

fail() {
    echo -e "${red}$*${plain}" >&2
    exit 1
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || fail "Please run this script as root."
}

detect_os() {
    [[ -f /etc/os-release ]] || fail "Cannot detect OS: /etc/os-release is missing."
    # shellcheck disable=SC1091
    source /etc/os-release
}

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo "amd64" ;;
        *) fail "This fast installer currently supports amd64 only. Detected: $(uname -m)" ;;
    esac
}

install_base() {
    log "Installing runtime dependencies..."
    case "${ID}" in
        ubuntu | debian | armbian)
            apt-get update
            apt-get install -y -q curl tar ca-certificates
            ;;
        centos)
            if [[ "${VERSION_ID:-}" =~ ^7 ]] || ! command -v dnf > /dev/null 2>&1; then
                yum makecache -y
                yum install -y curl tar ca-certificates
            else
                dnf makecache -y
                dnf install -y -q curl tar ca-certificates
            fi
            ;;
        rhel | rocky | almalinux | ol | fedora | amzn | virtuozzo)
            if command -v dnf > /dev/null 2>&1; then
                dnf makecache -y
                dnf install -y -q curl tar ca-certificates
            else
                yum makecache -y
                yum install -y curl tar ca-certificates
            fi
            ;;
        *)
            fail "Unsupported OS for fast installer: ${ID}"
            ;;
    esac
}

service_file() {
    case "${ID}" in
        ubuntu | debian | armbian)
            echo "x-ui.service.debian"
            ;;
        *)
            echo "x-ui.service.rhel"
            ;;
    esac
}

install_package() {
    local tmp_pkg
    tmp_pkg="/tmp/${PACKAGE_NAME}"

    log "Downloading ${PACKAGE_NAME}..."
    curl -fL -o "${tmp_pkg}" "${PACKAGE_URL}"

    if systemctl list-unit-files x-ui.service > /dev/null 2>&1; then
        systemctl stop x-ui > /dev/null 2>&1 || true
    fi

    log "Installing x-ui package..."
    rm -rf "${INSTALL_DIR}"
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    tar -xzf "${tmp_pkg}" -C "$(dirname "${INSTALL_DIR}")"
    rm -f "${tmp_pkg}"

    chmod +x "${INSTALL_DIR}/x-ui" "${INSTALL_DIR}/x-ui.sh"
    chmod +x "${INSTALL_DIR}/bin/xray-linux-amd64"

    cp -f "${INSTALL_DIR}/x-ui.sh" /usr/bin/x-ui
    chmod +x /usr/bin/x-ui

    cp -f "${INSTALL_DIR}/$(service_file)" "${SERVICE_DIR}/x-ui.service"
    chown root:root "${SERVICE_DIR}/x-ui.service"
    chmod 644 "${SERVICE_DIR}/x-ui.service"
}

start_service() {
    log "Starting x-ui service..."
    mkdir -p /var/log/x-ui
    systemctl daemon-reload
    systemctl enable x-ui
    systemctl restart x-ui
}

print_result() {
    echo
    log "Fast x-ui installation finished."
    echo -e "Package: ${PACKAGE_URL}"
    echo
    echo -e "Useful commands:"
    echo -e "  x-ui"
    echo -e "  systemctl status x-ui"
    echo
    warn "If this is a fresh install, run 'x-ui' to configure panel settings and login credentials."
}

main() {
    require_root
    detect_os
    arch > /dev/null
    install_base
    install_package
    start_service
    print_result
}

main "$@"
