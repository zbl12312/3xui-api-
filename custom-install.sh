#!/usr/bin/env bash
set -Eeuo pipefail

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

REPO_URL="${XUI_CUSTOM_REPO_URL:-https://github.com/zbl12312/3xui-api-.git}"
REPO_REF="${XUI_CUSTOM_REPO_REF:-main}"
BUILD_DIR="${XUI_CUSTOM_BUILD_DIR:-/tmp/3xui-api-build}"
INSTALL_DIR="${XUI_CUSTOM_INSTALL_DIR:-/usr/local/x-ui}"
SERVICE_DIR="${XUI_CUSTOM_SERVICE_DIR:-/etc/systemd/system}"
XRAY_VERSION="${XUI_CUSTOM_XRAY_VERSION:-v26.6.27}"
GO_VERSION="${XUI_CUSTOM_GO_VERSION:-1.26.5}"
NODE_MAJOR="${XUI_CUSTOM_NODE_MAJOR:-24}"
NPM_REGISTRY="${XUI_CUSTOM_NPM_REGISTRY:-https://registry.npmmirror.com}"

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
    case "${ID}" in
        ubuntu | debian | armbian | centos | rhel | rocky | almalinux | ol | fedora | amzn | virtuozzo)
            ;;
        *)
            fail "This custom installer currently supports Debian/Ubuntu and CentOS/RHEL-family systems. Detected: ${ID}"
            ;;
    esac
}

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo "amd64" ;;
        aarch64 | arm64 | armv8*) echo "arm64" ;;
        i386 | i686) echo "386" ;;
        armv7* | armv7 | arm) echo "armv7" ;;
        armv6* | armv6) echo "armv6" ;;
        armv5* | armv5) echo "armv5" ;;
        s390x) echo "s390x" ;;
        *) fail "Unsupported CPU architecture: $(uname -m)" ;;
    esac
}

xray_asset_arch() {
    case "$(arch)" in
        amd64) echo "64" ;;
        arm64) echo "arm64-v8a" ;;
        386) echo "32" ;;
        armv7) echo "arm32-v7a" ;;
        armv6) echo "arm32-v6" ;;
        armv5) echo "arm32-v5" ;;
        s390x) echo "s390x" ;;
    esac
}

xray_binary_name() {
    case "$(arch)" in
        amd64) echo "xray-linux-amd64" ;;
        arm64) echo "xray-linux-arm64" ;;
        386) echo "xray-linux-386" ;;
        armv7 | armv6 | armv5) echo "xray-linux-arm32" ;;
        s390x) echo "xray-linux-s390x" ;;
    esac
}

go_asset_arch() {
    case "$(arch)" in
        amd64) echo "amd64" ;;
        arm64) echo "arm64" ;;
        386) echo "386" ;;
        armv7 | armv6 | armv5) echo "armv6l" ;;
        s390x) echo "s390x" ;;
    esac
}

install_packages() {
    log "Installing build dependencies..."
    case "${ID}" in
        ubuntu | debian | armbian)
            apt-get update
            apt-get install -y -q git curl unzip tar ca-certificates build-essential
            ;;
        centos)
            if [[ "${VERSION_ID:-}" =~ ^7 ]] || ! command -v dnf > /dev/null 2>&1; then
                yum makecache -y
                yum install -y git curl unzip tar ca-certificates gcc gcc-c++ make
            else
                dnf makecache -y
                dnf install -y -q git curl unzip tar ca-certificates gcc gcc-c++ make
            fi
            ;;
        rhel | rocky | almalinux | ol | fedora | amzn | virtuozzo)
            if command -v dnf > /dev/null 2>&1; then
                dnf makecache -y
                dnf install -y -q git curl unzip tar ca-certificates gcc gcc-c++ make
            else
                yum makecache -y
                yum install -y git curl unzip tar ca-certificates gcc gcc-c++ make
            fi
            ;;
    esac
}

install_go() {
    local asset_arch file url
    asset_arch="$(go_asset_arch)"
    file="go${GO_VERSION}.linux-${asset_arch}.tar.gz"
    url="https://go.dev/dl/${file}"

    log "Installing Go ${GO_VERSION}..."
    curl -fL -o "/tmp/${file}" "${url}"
    rm -rf /usr/local/go
    tar -C /usr/local -xzf "/tmp/${file}"
    rm -f "/tmp/${file}"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt
}

cleanup_debian_node_packages() {
    log "Removing old distro Node.js packages..."
    apt-get remove -y -q nodejs npm libnode-dev nodejs-doc || true
    apt-get autoremove -y -q || true
    dpkg --configure -a
    apt-get --fix-broken install -y -q
}

install_node() {
    log "Installing Node.js ${NODE_MAJOR}.x..."
    case "${ID}" in
        ubuntu | debian | armbian)
            cleanup_debian_node_packages
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
            apt-get update
            apt-get install -y -q nodejs
            ;;
        *)
            curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
            if command -v dnf > /dev/null 2>&1; then
                dnf install -y -q nodejs
            else
                yum install -y nodejs
            fi
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

fetch_source() {
    log "Fetching custom 3x-ui source from ${REPO_URL}..."
    rm -rf "${BUILD_DIR}"
    git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${BUILD_DIR}"
}

configure_npm() {
    log "Configuring npm registry and retry settings..."
    npm config set registry "${NPM_REGISTRY}"
    npm config set fetch-retries 5
    npm config set fetch-retry-factor 2
    npm config set fetch-retry-mintimeout 20000
    npm config set fetch-retry-maxtimeout 120000
    npm config set timeout 300000
    npm cache clean --force || true
}

build_frontend() {
    log "Building frontend..."
    cd "${BUILD_DIR}/frontend"
    configure_npm
    npm install
    npm run build
}

build_backend() {
    log "Building x-ui binary..."
    cd "${BUILD_DIR}"
    mkdir -p internal/web/dist
    go build -o x-ui main.go
}

install_xray() {
    local asset_arch file url binary_name
    asset_arch="$(xray_asset_arch)"
    file="Xray-linux-${asset_arch}.zip"
    url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/${file}"
    binary_name="$(xray_binary_name)"

    log "Installing Xray-core ${XRAY_VERSION}..."
    mkdir -p "${INSTALL_DIR}/bin"
    cd "${INSTALL_DIR}/bin"
    rm -f "${file}" xray "${binary_name}"
    curl -fL -o "${file}" "${url}"
    unzip -o "${file}"
    rm -f "${file}"
    mv -f xray "${binary_name}"
    chmod +x "${binary_name}"
}

install_panel() {
    log "Installing x-ui panel..."
    if systemctl list-unit-files x-ui.service > /dev/null 2>&1; then
        systemctl stop x-ui > /dev/null 2>&1 || true
    fi

    mkdir -p "${INSTALL_DIR}"
    cp -f "${BUILD_DIR}/x-ui" "${INSTALL_DIR}/x-ui"
    chmod +x "${INSTALL_DIR}/x-ui"

    cp -f "${BUILD_DIR}/x-ui.sh" /usr/bin/x-ui
    chmod +x /usr/bin/x-ui

    cp -f "${BUILD_DIR}/$(service_file)" "${SERVICE_DIR}/x-ui.service"
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
    log "Custom 3x-ui installation finished."
    echo -e "Repository: ${REPO_URL}"
    echo -e "Xray-core: ${XRAY_VERSION}"
    echo -e "npm registry: ${NPM_REGISTRY}"
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
    log "Detected architecture: $(arch)"
    install_packages
    install_go
    install_node
    fetch_source
    build_frontend
    build_backend
    install_panel
    install_xray
    start_service
    print_result
}

main "$@"
