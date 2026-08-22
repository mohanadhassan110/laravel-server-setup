#!/usr/bin/env bash
# ==============================================================================
# 01-system-update.sh — تحديث النظام وتثبيت الحزم الأساسية
#
# يحدّث فهرس الحزم ويطوّر النظام، يضبط المنطقة الزمنية (اختياريًا)، ويثبّت
# مجموعة حزم أساسية يعتمد عليها باقي سكريبتات المشروع.
#
# Usage: sudo bash scripts/01-system-update.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

# Baseline tooling every later step assumes is present: curl/gnupg for
# third-party repo keys, software-properties-common for add-apt-repository,
# unzip/zip for Composer archives and assets, ufw for the firewall step.
readonly BASE_PACKAGES=(
    ca-certificates
    curl
    gnupg
    git
    unzip
    zip
    software-properties-common
    apt-transport-https
    lsb-release
    ufw
    cron
    htop
    less
)

main() {
    check_root
    check_os

    log_step "Step 1/9: System update and base packages"

    apt_get_update
    apt_upgrade
    install_base_packages
    set_timezone

    log_ok "System is up to date and base packages are installed."
}

apt_get_update() {
    log_info "Refreshing APT package index..."
    apt-get update -y
}

apt_upgrade() {
    # noninteractive keeps kernel/dpkg conffile prompts from blocking unattended
    # runs; existing config files are always kept.
    log_info "Upgrading installed packages..."
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

install_base_packages() {
    local missing=()
    local pkg
    for pkg in "${BASE_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} == 0 )); then
        log_ok "All base packages already installed."
        return 0
    fi

    log_info "Installing base packages: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    log_ok "Base packages installed."
}

set_timezone() {
    local current_tz answer

    current_tz="$(timedatectl show -p Timezone --value 2>/dev/null || printf 'UTC')"
    echo ""
    answer="$(ask "Timezone to set (leave empty to keep ${current_tz})" "")"
    [[ -z "$answer" ]] && return 0

    if ! timedatectl list-timezones | grep -Fxq "$answer"; then
        log_warn "'${answer}' is not a valid timezone - skipping. Current: ${current_tz}"
        return 0
    fi

    timedatectl set-timezone "$answer"
    log_ok "Timezone set to ${answer}."
}

main "$@"
