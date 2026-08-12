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
PANEL_USERNAME=""
PANEL_PASSWORD=""
PANEL_PORT=""
PANEL_WEB_BASE_PATH=""
PANEL_HOST=""

gen_random_string() {
    local length="$1"
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -base64 $((length * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
    fi
}

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

get_public_host() {
    local public_ip
    public_ip=$(curl -fsS --max-time 6 https://api.ipify.org 2> /dev/null || true)
    if [[ -n "${public_ip}" ]]; then
        echo "${public_ip}"
        return
    fi

    hostname -I 2> /dev/null | awk '{print $1}'
}

normalize_url_path() {
    local path="$1"
    path="${path#/}"
    path="${path%/}"

    if [[ -z "${path}" ]]; then
        echo "/"
    else
        echo "/${path}/"
    fi
}

install_base() {
    log "Installing runtime dependencies..."
    case "${ID}" in
        ubuntu | debian | armbian)
            apt-get update
            apt-get install -y -q curl tar ca-certificates openssl
            ;;
        centos)
            if [[ "${VERSION_ID:-}" =~ ^7 ]] || ! command -v dnf > /dev/null 2>&1; then
                yum makecache -y
                yum install -y curl tar ca-certificates openssl
            else
                dnf makecache -y
                dnf install -y -q curl tar ca-certificates openssl
            fi
            ;;
        rhel | rocky | almalinux | ol | fedora | amzn | virtuozzo)
            if command -v dnf > /dev/null 2>&1; then
                dnf makecache -y
                dnf install -y -q curl tar ca-certificates openssl
            else
                yum makecache -y
                yum install -y curl tar ca-certificates openssl
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

configure_panel() {
    local info has_default web_base_path

    info=$("${INSTALL_DIR}/x-ui" setting -show true 2> /dev/null || true)
    has_default=$(echo "${info}" | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}' || true)
    web_base_path=$(echo "${info}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##' || true)

    if [[ "${has_default}" == "true" || ${#web_base_path} -lt 4 ]]; then
        PANEL_USERNAME="${XUI_USERNAME:-$(gen_random_string 10)}"
        PANEL_PASSWORD="${XUI_PASSWORD:-$(gen_random_string 10)}"
        PANEL_PORT="${XUI_PANEL_PORT:-$(shuf -i 1024-62000 -n 1)}"
        PANEL_WEB_BASE_PATH="${XUI_WEB_BASE_PATH:-$(gen_random_string 18)}"

        log "Configuring initial panel credentials..."
        "${INSTALL_DIR}/x-ui" setting \
            -username "${PANEL_USERNAME}" \
            -password "${PANEL_PASSWORD}" \
            -port "${PANEL_PORT}" \
            -webBasePath "${PANEL_WEB_BASE_PATH}"
    fi
}

load_panel_settings() {
    local info

    info=$("${INSTALL_DIR}/x-ui" setting -show true 2> /dev/null || true)
    PANEL_PORT="${PANEL_PORT:-$(echo "${info}" | grep -Eo 'port: .+' | awk '{print $2}' || true)}"
    PANEL_WEB_BASE_PATH="${PANEL_WEB_BASE_PATH:-$(echo "${info}" | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##' || true)}"
    PANEL_HOST="${XUI_PANEL_HOST:-$(get_public_host)}"
}

print_result() {
    local panel_path panel_url

    load_panel_settings
    panel_path="$(normalize_url_path "${PANEL_WEB_BASE_PATH}")"
    panel_url="http://${PANEL_HOST}:${PANEL_PORT}${panel_path}"

    echo
    log "Fast x-ui installation finished."
    echo -e "Package: ${PACKAGE_URL}"
    if [[ -n "${PANEL_HOST}" && -n "${PANEL_PORT}" ]]; then
        echo
        echo -e "${green}Panel URL:    ${panel_url}${plain}"
        echo -e "${green}API Docs:     ${panel_url}api-docs${plain}"
        echo -e "${green}OpenAPI JSON: ${panel_url}panel/api/openapi.json${plain}"
    fi
    if [[ -n "${PANEL_USERNAME}" ]]; then
        echo
        echo -e "${green}Initial panel settings:${plain}"
        echo -e "${green}Username:    ${PANEL_USERNAME}${plain}"
        echo -e "${green}Password:    ${PANEL_PASSWORD}${plain}"
        echo -e "${green}Port:        ${PANEL_PORT}${plain}"
        echo -e "${green}WebBasePath: ${PANEL_WEB_BASE_PATH}${plain}"
        echo -e "${yellow}Save these credentials securely.${plain}"
    fi
    echo
    echo -e "Useful commands:"
    echo -e "  x-ui"
    echo -e "  systemctl status x-ui"
    echo
    warn "Create API tokens after login: Settings -> API Tokens."
    warn "Run 'x-ui' to open the management menu."
}

main() {
    require_root
    detect_os
    arch > /dev/null
    install_base
    install_package
    configure_panel
    start_service
    print_result
}

main "$@"
