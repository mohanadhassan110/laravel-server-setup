#!/usr/bin/env bash
# ==============================================================================
# 06-install-composer-node.sh — تثبيت Composer و Node.js LTS وأدوات الواجهة
#
#   1) Composer: أحدث نسخة عبر المثبّت الرسمي مع التحقق من بصمة sha384
#   2) Node.js: أحدث إصدار LTS عبر مستودع NodeSource الرسمي
#   3) npm + yarn عالميًا لبناء أصول الـ frontend (Vite)
#
# يتطلب تشغيل scripts/03-install-php.sh أولًا.
#
# Usage: sudo bash scripts/06-install-composer-node.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

readonly COMPOSER_BIN="/usr/local/bin/composer"

main() {
    check_root
    check_os

    log_step "Step 6/9: Composer and Node.js LTS installation"

    command_exists php || die "php not found. Run scripts/03-install-php.sh first."

    install_composer
    install_node_lts
    install_yarn

    echo ""
    log_ok "Composer : $(composer --version 2>/dev/null | head -n1)"
    log_ok "Node.js  : $(node --version)  /  npm $(npm --version)"
    log_ok "Yarn     : $(yarn --version)"
}

install_composer() {
    if command_exists composer; then
        log_ok "Composer already installed ($(composer --version 2>/dev/null | head -n1))."
        return 0
    fi

    log_info "Downloading the official Composer installer..."

    local installer expected_sig actual_sig
    installer="$(mktemp /tmp/composer-setup-XXXXXX.php)"

    # Cleanup on any exit path so no half-downloaded installers linger in /tmp.
    trap 'rm -f "$installer"' RETURN

    # The published signature corresponds to the current installer build;
    # comparing sha384 digests guarantees we execute exactly what upstream
    # shipped and nothing tampered with along the way.
    expected_sig="$(curl -fsSL https://composer.github.io/installer.sig)"
    curl -fsSL https://getcomposer.org/installer -o "$installer"
    actual_sig="$(sha384sum "$installer" | awk '{print $1}')"

    if [[ "$expected_sig" != "$actual_sig" ]]; then
        die "Composer installer checksum mismatch! Expected ${expected_sig}, got ${actual_sig}.
The download may be corrupted or tampered with - aborting."
    fi
    log_ok "Installer signature verified (sha384)."

    php "$installer" --install-dir="$(dirname "$COMPOSER_BIN")" --filename="$(basename "$COMPOSER_BIN")" --quiet
    chmod +x "$COMPOSER_BIN"
    log_ok "Composer installed at ${COMPOSER_BIN}."
}

install_node_lts() {
    if command_exists node; then
        log_ok "Node.js already installed ($(node --version))."
        return 0
    fi

    log_info "Adding the NodeSource repository (LTS channel)..."

    local setup_script
    setup_script="$(mktemp /tmp/nodesource-setup-XXXXXX.sh)"

    # Downloading to a file instead of piping straight into bash means the
    # script is on disk (auditable) and a truncated download cannot execute.
    if ! curl -fsSL https://deb.nodesource.com/setup_lts.x -o "$setup_script"; then
        rm -f "$setup_script"
        die "Could not download the NodeSource setup script - check network access."
    fi
    bash "$setup_script"
    rm -f "$setup_script"

    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    log_ok "Node.js $(node --version) installed with bundled npm $(npm --version)."
}

install_yarn() {
    if command_exists yarn; then
        log_ok "Yarn already installed (v$(yarn --version))."
        return 0
    fi

    log_info "Installing Yarn globally via npm..."
    npm install -g --silent yarn
    log_ok "Yarn v$(yarn --version) installed."
}

main "$@"
