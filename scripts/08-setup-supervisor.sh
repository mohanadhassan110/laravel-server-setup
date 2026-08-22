#!/usr/bin/env bash
# ==============================================================================
# 08-setup-supervisor.sh — تشغيل Laravel Queue Workers عبر Supervisor
#
# يثبّت Supervisor ويولّد ملف config لكل queue من قالب
# templates/supervisor-worker.conf مع إعادة تشغيل تلقائية عند الأعطال.
#
# Usage: sudo bash scripts/08-setup-supervisor.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

readonly WORKER_TEMPLATE="$PROJECT_ROOT/templates/supervisor-worker.conf"
readonly SUPERVISOR_CONF_DIR="/etc/supervisor/conf.d"

main() {
    check_root
    check_os

    log_step "Step 8/9: Supervisor queue workers"

    install_supervisor
    install_worker_config
    start_workers
}

install_supervisor() {
    if command_exists supervisorctl; then
        log_ok "Supervisor already installed."
    else
        log_info "Installing supervisor..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y supervisor
        log_ok "Supervisor installed."
    fi

    systemctl enable --now supervisor >/dev/null 2>&1 || true
    systemctl is-active --quiet supervisor || die "supervisord failed to start. Check: journalctl -u supervisor"
}

install_worker_config() {
    local project_path program_name queue num_workers rendered

    project_path="$(get_config PROJECT_PATH "/var/www/laravel")"
    program_name="$(ask "Supervisor program name" "laravel-worker")"
    validate_identifier "$program_name"

    echo ""
    log_info "Queue name(s): comma-separated, e.g. 'default' or 'default,emails'."
    queue="$(ask "Queue(s) to consume" "default")"

    num_workers="$(ask "Number of worker processes" "2")"
    if ! printf '%s' "$num_workers" | grep -Eq '^[1-9][0-9]*$'; then
        die "Number of workers must be a positive integer (got '${num_workers}')."
    fi

    [[ -f "$WORKER_TEMPLATE" ]] || die "Template not found: ${WORKER_TEMPLATE}"

    # The worker writes into storage/logs before Laravel may exist there yet,
    # so create the directory now with correct ownership to avoid a crash loop.
    mkdir -p "${project_path}/storage/logs"
    chown -R www-data:www-data "${project_path}/storage"

    rendered="${SUPERVISOR_CONF_DIR}/${program_name}.conf"
    sed -e "s|{{PROGRAM_NAME}}|${program_name}|g" \
        -e "s|{{PROJECT_PATH}}|${project_path}|g" \
        -e "s|{{QUEUE_NAME}}|${queue}|g" \
        -e "s|{{NUM_WORKERS}}|${num_workers}|g" \
        "$WORKER_TEMPLATE" >"$rendered"

    set_config QUEUE_NAME "$queue"
    set_config NUM_WORKERS "$num_workers"
    set_config PROGRAM_NAME "$program_name"

    log_ok "Worker config written to ${rendered}."
}

start_workers() {
    # reread+update applies new/changed programs; existing ones keep running.
    supervisorctl reread
    supervisorctl update

    # update starts *new* groups automatically but restarts changed ones only
    # after their stopwaitsecs; an explicit start is harmless when running.
    supervisorctl start "all" >/dev/null 2>&1 || true

    echo ""
    supervisorctl status
    log_ok "Queue workers are managed by Supervisor (autorestart on failure)."
}

validate_identifier() {
    local value="$1"
    printf '%s' "$value" | grep -Eq '^[A-Za-z0-9_-]+$' \
        || die "Program name must contain only letters, digits, _ or - (got '${value}')."
}

main "$@"
