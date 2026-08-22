#!/usr/bin/env bash
# ==============================================================================
# 02-install-nginx.sh — تثبيت NGINX وإعداد Virtual Host لتطبيق Laravel
#
# يسأل عن الدومين ومسار المشروع، يحفظهما في .setup-config، ثم يولّد ملف الـ
# vhost من templates/nginx-laravel.conf ويوقف الموقع الافتراضي.
#
# Usage: sudo bash scripts/02-install-nginx.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

readonly VHOST_NAME="laravel.conf"
readonly NGINX_TEMPLATE="$PROJECT_ROOT/templates/nginx-laravel.conf"

# --skip-questions re-renders the vhost from stored config values; it is used
# by scripts/03 after a PHP version switch changes the FPM socket name.
SKIP_QUESTIONS=false

main() {
    if [[ "${1:-}" == "--skip-questions" ]]; then
        SKIP_QUESTIONS=true
    fi

    check_root
    check_os

    log_step "Step 2/9: NGINX installation"

    install_nginx

    if [[ "$SKIP_QUESTIONS" == true ]]; then
        [[ -n "$(get_config DOMAIN "")" ]] || die "--skip-questions needs a stored DOMAIN; run interactively first."
        log_info "Reusing stored settings: $(get_config DOMAIN "")"
    else
        ask_site_settings
    fi

    create_project_directory
    render_vhost
    enable_site
}

install_nginx() {
    if command_exists nginx; then
        log_ok "NGINX already installed ($(nginx -v 2>&1))."
        return 0
    fi

    log_info "Installing NGINX..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
    log_ok "NGINX installed."
}

ask_site_settings() {
    local domain project_path current_domain

    current_domain="$(get_config DOMAIN "")"
    domain="$(ask "Primary domain for this server (e.g. example.com)" "$current_domain")"
    domain="$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | xargs)"

    # Fail fast on obviously invalid input instead of shipping a broken vhost.
    if ! printf '%s' "$domain" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
        die "'${domain}' does not look like a valid domain name."
    fi

    project_path="$(ask "Project deployment path" "/var/www/${domain}")"

    set_config DOMAIN "$domain"
    set_config PROJECT_PATH "$project_path"

    log_ok "Domain: ${domain}"
    log_ok "Project path: ${project_path}"
}

create_project_directory() {
    local project_path
    project_path="$(get_config PROJECT_PATH "")"

    mkdir -p "${project_path}/public"
    chown -R www-data:www-data "$project_path"
    chmod 755 "$project_path"

    # Placeholder page proves the vhost + PHP wiring works before the real app
    # is deployed; it gets replaced by the Laravel public/ directory later.
    if [[ ! -f "${project_path}/public/index.php" ]]; then
        cat >"${project_path}/public/index.php" <<'PHP'
<?php
phpinfo();
PHP
        chown www-data:www-data "${project_path}/public/index.php"
        log_ok "Placeholder index.php created at ${project_path}/public."
    fi
}

render_vhost() {
    local domain project_path php_version rendered

    domain="$(get_config DOMAIN "")"
    project_path="$(get_config PROJECT_PATH "")"
    php_version="$(get_config PHP_VERSION "8.3")"

    if [[ ! -f "$NGINX_TEMPLATE" ]]; then
        die "Template not found: ${NGINX_TEMPLATE}"
    fi

    rendered="/etc/nginx/sites-available/${VHOST_NAME}"
    # sed with | delimiters avoids escaping the slashes inside paths.
    sed -e "s|{{DOMAIN}}|${domain}|g" \
        -e "s|{{PROJECT_PATH}}|${project_path}|g" \
        -e "s|{{PHP_VERSION}}|${php_version}|g" \
        "$NGINX_TEMPLATE" >"$rendered"

    log_ok "Vhost rendered at ${rendered} (PHP ${php_version})."
}

enable_site() {
    # The default welcome site occupies server_name _ and would shadow our
    # vhost, so it must go before enabling the Laravel one.
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        log_info "Disabled the default nginx site."
    fi

    ln -sfn "/etc/nginx/sites-available/${VHOST_NAME}" "/etc/nginx/sites-enabled/${VHOST_NAME}"

    # Validate BEFORE reloading: a config typo must never take a running
    # web server down.
    if ! nginx -t 2>/dev/null; then
        nginx -t || true   # surface the actual error text for the operator
        die "NGINX configuration test failed - see the error above."
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl reload nginx
    log_ok "NGINX reloaded with the Laravel vhost enabled."
}

main "$@"
