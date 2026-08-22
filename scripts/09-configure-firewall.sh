#!/usr/bin/env bash
# ==============================================================================
# 09-configure-firewall.sh — ضبط جدار الحماية UFW
#
# يسمح فقط بـ SSH و HTTP و HTTPS، مع تأكيد صريح من المستخدم قبل تفعيل الـ
# firewall حتى لا يقفل أحد نفسه خارج السيرفر بالغلط.
#
# Usage: sudo bash scripts/09-configure-firewall.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

main() {
    check_root
    check_os

    log_step "Step 9/9: UFW firewall configuration"

    install_ufw
    add_rules
    enable_firewall
}

install_ufw() {
    if command_exists ufw; then
        log_ok "UFW already installed."
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw
    log_ok "UFW installed."
}

# Read the effective SSH port from sshd_config so a hardened server using a
# non-standard port does not get locked out by a hardcoded 22/tcp rule.
current_ssh_port() {
    local port=""
    if [[ -r /etc/ssh/sshd_config ]]; then
        port="$(awk '$1 == "Port" { print $2; exit }' /etc/ssh/sshd_config)"
    fi
    printf '%s' "${port:-22}"
}

add_rules() {
    local ssh_port
    ssh_port="$(current_ssh_port)"

    # Sensible defaults before anything is enabled: deny inbound, allow the
    # server's own outbound connections (apt, composer, webhooks...).
    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null

    log_info "Allowing SSH on port ${ssh_port}/tcp (rate-limited against brute force)..."
    ufw limit "${ssh_port}/tcp" >/dev/null

    log_info "Allowing HTTP (80/tcp) and HTTPS (443/tcp)..."
    ufw allow 80/tcp  >/dev/null comment 'HTTP'
    ufw allow 443/tcp >/dev/null comment 'HTTPS'

    echo ""
    ufw status numbered || true
}

enable_firewall() {
    if systemctl is-active --quiet ufw && [[ "$(ufw status | awk '{print $2}')" == "active" ]]; then
        log_ok "UFW is already enabled - rules above are live."
        return 0
    fi

    echo ""
    log_warn "Enabling UFW will apply 'default deny incoming' immediately."
    log_warn "Make sure you can reach the server via the SSH port shown above."
    echo ""

    # The one destructive step in this whole project - hence an explicit,
    # default-no confirmation instead of running unattended.
    if ! confirm "Enable the firewall NOW?"; then
        set_config FIREWALL_STATUS "pending"
        log_warn "Rules staged but NOT enabled. Enable later with: sudo ufw enable"
        return 0
    fi

    # --force skips UFW's own interactive prompt because we already asked.
    ufw --force enable >/dev/null
    set_config FIREWALL_STATUS "enabled"
    echo ""
    ufw status verbose
    log_ok "UFW enabled. Only SSH/HTTP/HTTPS are reachable from outside."
}

main "$@"
