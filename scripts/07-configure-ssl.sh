#!/usr/bin/env bash
# ==============================================================================
# 07-configure-ssl.sh — إصدار شهادة SSL مجانية عبر Certbot/Let's Encrypt
#
# يقرأ الدومين المحفوظ من .setup-config (الذي أدخلته في سكريبت الـ nginx)،
# يتحقق من أن الدومين يشير للسيرفر، ثم يصدر الشهادة ويجعل HTTPS إلزاميًا.
# يمكن تخطي الخطوة بأمان لو ما عندك دومين حقيقي بعد.
#
# Usage: sudo bash scripts/07-configure-ssl.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

main() {
    check_root
    check_os

    log_step "Step 7/9: SSL certificate (Let's Encrypt)"

    install_certbot

    local domain
    domain="$(get_config DOMAIN "")"

    if [[ -z "$domain" ]]; then
        log_warn "No domain is stored in the setup config."
        set_config SSL_STATUS "skipped"
        log_warn "Run scripts/02-install-nginx.sh first, then re-run this step."
        return 0
    fi

    # A real certificate needs real DNS; guessing would burn Let's Encrypt
    # rate limits on doomed issuance attempts.
    if ! confirm "Is https://${domain} DNS pointing to THIS server and reachable on port 80?"; then
        set_config SSL_STATUS "skipped"
        log_warn "SSL skipped. Re-run this step once DNS is set up:"
        log_warn "  sudo bash ${SCRIPT_DIR}/07-configure-ssl.sh"
        return 0
    fi

    issue_certificate "$domain"
}

install_certbot() {
    if command_exists certbot && dpkg -s python3-certbot-nginx >/dev/null 2>&1; then
        log_ok "Certbot already installed ($(certbot --version 2>&1 | awk '{print $2}'))."
        return 0
    fi

    log_info "Installing certbot with the nginx plugin..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx
    log_ok "Certbot installed (auto-renewal timer ships enabled)."
}

issue_certificate() {
    local domain="$1"
    local email

    echo ""
    email="$(ask "Email address for expiry notices and the LE account" "$(get_config SSL_EMAIL "")")"
    [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || die "'${email}' does not look like a valid email address."
    set_config SSL_EMAIL "$email"

    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        log_ok "A certificate for ${domain} already exists - forcing renewal instead."
        certbot renew --cert-name "$domain" --nginx --non-interactive
    else
        # --redirect makes certbot add the HTTP->HTTPS server block itself;
        # --non-interactive requires all answers supplied up front.
        log_info "Requesting a certificate for ${domain}..."
        certbot --nginx \
            -d "$domain" \
            --non-interactive \
            --agree-tos \
            --email "$email" \
            --redirect
    fi

    if [[ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        set_config SSL_STATUS "failed"
        die "Certificate files were not created - review the certbot output above."
    fi

    systemctl reload nginx
    set_config SSL_STATUS "active"
    echo ""
    log_ok "SSL is live: https://${domain}"
    log_ok "Auto-renewal is handled by systemd (certbot.timer) - verify with:"
    log_ok "  systemctl list-timers | grep certbot"
}

main "$@"
