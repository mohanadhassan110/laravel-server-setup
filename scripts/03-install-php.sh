#!/usr/bin/env bash
# ==============================================================================
# 03-install-php.sh — تثبيت PHP-FPM مع الإضافات التي يحتاجها Laravel
#
# يستخدم PPA الشهير ondrej/php للحصول على أحدث إصدارات PHP على Ubuntu،
# ثم يعيد توليد ملف الـ vhost ليتوافق مع نسخة PHP المختارة.
#
# Usage: sudo bash scripts/03-install-php.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# Versions currently receiving security support from upstream php.net.
readonly SUPPORTED_VERSIONS=("8.1" "8.2" "8.3" "8.4")
readonly DEFAULT_VERSION="8.3"

# Everything a standard Laravel 10/11/12 application links against:
# mysql -> Eloquent driver, redis -> cache/queues, others are composer
# hard requirements or extremely common package dependencies.
readonly EXTENSIONS=(
    cli
    fpm
    mysql
    mbstring
    xml
    curl
    zip
    intl
    gd
    bcmath
    opcache
    redis
)

main() {
    check_root
    check_os

    log_step "Step 3/9: PHP-FPM installation"

    local version
    version="$(pick_version)"
    set_config PHP_VERSION "$version"

    install_php "$version"
    tune_php_ini "$version"

    # Re-render the vhost because the FPM socket path contains the version.
    if [[ -n "$(get_config DOMAIN "")" ]]; then
        log_info "Re-rendering nginx vhost for PHP ${version}..."
        "${SCRIPT_DIR}/02-install-nginx.sh" --skip-questions
    fi

    log_ok "PHP ${version} ready. FPM socket: /run/php/php${version}-fpm.sock"
}

pick_version() {
    local current
    current="$(get_config PHP_VERSION "$DEFAULT_VERSION")"

    echo
    log_info "Supported versions: ${SUPPORTED_VERSIONS[*]}"
    local answer
    answer="$(ask "PHP version to install" "$current")"

    local v
    for v in "${SUPPORTED_VERSIONS[@]}"; do
        if [[ "$answer" == "$v" ]]; then
            printf '%s\n' "$v"
            return 0
        fi
    done
    die "Unsupported PHP version '${answer}'. Choose one of: ${SUPPORTED_VERSIONS[*]}."
}

install_php() {
    local version="$1"

    if dpkg -s "php${version}-fpm" >/dev/null 2>&1; then
        log_ok "PHP ${version}-FPM already installed."
        systemctl enable --now "php${version}-fpm" >/dev/null 2>&1 || true
        return 0
    fi

    log_info "Adding ondrej/php PPA..."
    # The PPA is the de-facto standard for up-to-date PHP on Ubuntu; pulling it
    # once here means security releases arrive through normal apt upgrades.
    add-apt-repository -y ppa:ondrej/php >/dev/null
    apt-get update -y

    log_info "Installing PHP ${version} and extensions (${EXTENSIONS[*]})..."
    local pkgs=()
    local ext
    for ext in "${EXTENSIONS[@]}"; do
        pkgs+=("php${version}-${ext}")
    done
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"

    systemctl enable --now "php${version}-fpm" >/dev/null 2>&1 || true
    log_ok "PHP $(php -r 'echo PHP_VERSION;') installed with FPM enabled."
}

# Apply pragmatic production defaults. Values are written only when they differ
# from what is already set, keeping repeated runs side-effect free.
tune_php_ini() {
    local version="$1"
    local ini_file="/etc/php/${version}/fpm/php.ini"

    if [[ ! -f "$ini_file" ]]; then
        log_warn "php.ini not found at ${ini_file} - skipping tuning."
        return 0
    fi

    cp "$ini_file" "${ini_file}.orig-backup" 2>/dev/null || true

    set_ini_value "$ini_file" "upload_max_filesize" "32M"
    set_ini_value "$ini_file" "post_max_size"       "32M"
    set_ini_value "$ini_file" "memory_limit"        "256M"
    set_ini_value "$ini_file" "max_execution_time"  "120"
    set_ini_value "$ini_file" "date.timezone"       "UTC"

    systemctl reload "php${version}-fpm"
    log_ok "php.ini tuned (uploads 32M, memory 256M, timezone UTC)."
}

# Replace an existing directive in place, or append it when commented out.
set_ini_value() {
    local file="$1"
    local key="$2"
    local value="$3"

    if grep -qE "^${key}\s*=" "$file"; then
        sed -i -E "s|^(${key})\s*=.*|\1 = ${value}|" "$file"
    else
        printf '\n%s = %s\n' "$key" "$value" >>"$file"
    fi
}

main "$@"
