#!/usr/bin/env bash
# ==============================================================================
# 05-install-redis.sh — تثبيت Redis وتأمينه كـ cache/queue لتطبيق Laravel
#
# الإعدادات المطبّقة:
#   - الربط على localhost فقط (لا وصول خارجي للسيرفر)
#   - protected-mode مفعل
#   - تعطيل الأوامر الخطيرة FLUSHALL/FLUSHDB/CONFIG/KEYS
#     (نُبقي FLUSHDB متاحًا لأن artisan cache:clear يعتمد عليه)
#
# Usage: sudo bash scripts/05-install-redis.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

readonly REDIS_CONF="/etc/redis/redis.conf"
readonly HARDENING_MARKER="# --- laravel-server-setup hardening ---"

main() {
    check_root
    check_os

    log_step "Step 5/9: Redis installation and hardening"

    install_redis
    harden_redis_config
    verify_redis
}

install_redis() {
    if ! command_exists redis-server; then
        log_info "Installing redis-server..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server
        log_ok "Redis installed."
    else
        log_ok "Redis already installed."
    fi

    systemctl enable --now redis-server >/dev/null 2>&1 || true
    systemctl is-active --quiet redis-server || die "redis-server failed to start. Check: journalctl -u redis-server"
}

harden_redis_config() {
    [[ -f "$REDIS_CONF" ]] || die "Config not found at ${REDIS_CONF} - unexpected Redis layout."

    if grep -qF "$HARDENING_MARKER" "$REDIS_CONF"; then
        log_ok "Redis hardening already applied - skipping."
        return 0
    fi

    # Keep an untouched copy so operators can diff/revert easily.
    cp "$REDIS_CONF" "${REDIS_CONF}.orig-backup" 2>/dev/null || true

    # Appending to the end of redis.conf wins over earlier directives (last
    # match takes precedence), so this overrides the distro defaults without
    # fragile in-place sed edits of long vendor lines.
    cat >>"$REDIS_CONF" <<EOF

${HARDENING_MARKER}
bind 127.0.0.1 ::1
protected-mode yes

# Renaming to the empty string disables these commands entirely.
# FLUSHALL/FLUSHDB: catastrophic data wipes (FLUSHDB stays available because
#   Laravel's cache:clear issues it).
# CONFIG: runtime reconfiguration, a classic exploit vector.
# KEYS: O(N) command that can freeze production under load.
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command KEYS ""
EOF

    systemctl restart redis-server
    log_ok "Hardened config applied and Redis restarted."
}

verify_redis() {
    local pong
    pong="$(redis-cli ping 2>/dev/null || true)"

    if [[ "$pong" != "PONG" ]]; then
        die "Redis did not answer PING with PONG (got '${pong:-no reply}'). Check: journalctl -u redis-server"
    fi
    log_ok "Redis responds on localhost:6379 (PING -> PONG)."
}

main "$@"
