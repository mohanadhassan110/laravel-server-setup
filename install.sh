#!/usr/bin/env bash
# ==============================================================================
# install.sh — السكريبت الرئيسي لمشروع laravel-server-setup
#
# يشغّل خطوات إعداد سيرفر Ubuntu لاستضافة Laravel بالترتيب الصحيح:
#   1) تحديث النظام          6) Composer + Node.js
#   2) NGINX + vhost         7) SSL عبر Let's Encrypt
#   3) PHP-FPM               8) Supervisor (queue workers)
#   4) MySQL                 9) جدار الحماية UFW
#   5) Redis
#
# يعمل بقائمة تفاعلية، أو بوضع غير تفاعلي:
#   sudo bash install.sh --all            # كل الخطوات بالترتيب
#   sudo bash install.sh --only 2,4       # خطوات محددة فقط
#   sudo bash install.sh --summary        # طباعة الملخص النهائي
#
# Usage: sudo bash install.sh [--all | --only N,N | --summary]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/lib/helpers.sh"

readonly SCRIPTS_SUBDIR="scripts"

STEP_FILES=(
    "01-system-update.sh"
    "02-install-nginx.sh"
    "03-install-php.sh"
    "04-install-mysql.sh"
    "05-install-redis.sh"
    "06-install-composer-node.sh"
    "07-configure-ssl.sh"
    "08-setup-supervisor.sh"
    "09-configure-firewall.sh"
)

STEP_TITLES=(
    "System update & base packages"
    "NGINX + Laravel vhost"
    "PHP-FPM & extensions"
    "MySQL server & app database"
    "Redis cache/queue + hardening"
    "Composer + Node.js LTS"
    "SSL certificate (Let's Encrypt)"
    "Supervisor queue workers"
    "UFW firewall"
)

# Per-run status map: "-" not attempted, "ok", "FAILED".
declare -A STEP_STATUS=()

main() {
    check_root
    check_os

    trap 'echo ""; log_warn "Interrupted - you can re-run install.sh anytime; steps are idempotent."; exit 130' INT TERM

    print_banner

    case "${1:-}" in
        --all)     run_all ;;
        --only)    [[ -n "${2:-}" ]] || die "--only requires a comma-separated list, e.g. --only 1,4,9."
                   run_selected "$2" ;;
        --summary) ;;
        "")        menu_loop ;;
        *)         die "Unknown option '${1}'. Use --all, --only <n,n> or --summary." ;;
    esac

    print_results_table
    echo ""
    print_summary
}

# ------------------------------------------------------------------------------
# Step execution — تشغيل الخطوات وتتبّع حالتها
# ------------------------------------------------------------------------------

run_step() {
    local index="$1"      # zero-based
    local file title
    file="${STEP_FILES[$index]}"
    title="${STEP_TITLES[$index]}"

    log_step "[Step $((index + 1))/${#STEP_FILES[@]}] ${title}"

    if bash "${SCRIPT_DIR}/${SCRIPTS_SUBDIR}/${file}"; then
        STEP_STATUS[$index]="ok"
        log_ok "${title} - completed."
    else
        STEP_STATUS[$index]="FAILED"
        log_error "${title} - failed."
        return 1
    fi
}

run_all() {
    local i
    for i in "${!STEP_FILES[@]}"; do
        # A failed step aborts the full run on purpose: later steps depend on
        # earlier ones, and every script is safe to re-run after a fix.
        run_step "$i" || die "Full setup aborted at step $((i + 1)). Fix the issue above, then re-run this script."
    done
}

run_selected() {
    local selection="$1"
    local choice i total="${#STEP_FILES[@]}"

    IFS=',' read -r -a choices <<<"$selection"
    for choice in "${choices[@]}"; do
        # Trim whitespace so "2, 4" behaves like "2,4".
        choice="$(printf '%s' "$choice" | xargs)"
        if ! printf '%s' "$choice" | grep -Eq '^[0-9]+$' || (( choice < 1 || choice > total )); then
            die "'${choice}' is not a valid step number (1-${total})."
        fi
    done

    # Sorted numeric order keeps dependency order even if the user typed 9 first.
    local sorted
    sorted="$(printf '%s\n' "${choices[@]}" | sort -n | uniq)"

    while read -r choice; do
        [[ -z "$choice" ]] && continue
        i=$((choice - 1))
        if [[ "${STEP_STATUS[$i]:--}" == "ok" ]]; then
            continue   # never run the same step twice in one session
        fi
        run_step "$i" || log_error "Continuing with remaining selected steps despite the failure."
    done <<<"$sorted"
}

# ------------------------------------------------------------------------------
# Interactive menu — القائمة التفاعلية
# ------------------------------------------------------------------------------

menu_loop() {
    show_menu
    local choice
    while read -r choice; do
        case "$choice" in
            a|A)
                run_all
                break
                ;;
            q|Q)
                log_info "Bye!"
                exit 0
                ;;
            s|S)
                print_summary
                echo ""
                show_menu
                continue
                ;;
            "" )
                show_menu
                continue
                ;;
            *[!0-9]*)
                log_warn "Please enter numbers only, comma-separated (e.g. 1,2,3)."
                continue
                ;;
            *)
                if run_selected "$choice"; then
                    :
                else
                    log_error "Some steps failed - see output above."
                fi
                break
                ;;
        esac
    done
}

show_menu() {
    echo ""
    printf '%b\n' "${C_BOLD}Choose what to do:${C_RESET}"
    printf '%b\n' "  ${C_CYAN}a${C_RESET}) Run ALL steps in order (recommended for a fresh server)"
    local i
    for i in "${!STEP_FILES[@]}"; do
        printf '%b\n' "  ${C_CYAN}$((i + 1))${C_RESET}) ${STEP_TITLES[$i]}"
    done
    printf '%b\n' "  ${C_CYAN}s${C_RESET}) Show current setup summary"
    printf '%b\n' "  ${C_CYAN}q${C_RESET}) Quit"
    printf '%b' "${C_CYAN}? Enter 'a', step numbers (e.g. 1,4), 's' or 'q':${C_RESET} "
}

print_banner() {
    printf '%b\n' "${C_CYAN}${C_BOLD}"
    cat <<'BANNER'
    _                                        _____                      _
    | |                                      / ____|                    | |
    | |     __ _ ___  ___ _ ____   _____ _ __| (___   ___  ___ _ __ ___| |
    | |    / _` / __|/ _ \ '__\ \ / / _ \ '__|\___ \ / _ \/ _ \ '__/ _ \ |
    | |___| (_| \__ \  __/ |   \ V /  __/ |   ____) |  __/  __/ | |  __/ |
    |______\__,_|___/\___|_|    \_/ \___|_|  |_____(_)___|\___|_|  \___|_|

    Automated Ubuntu 22.04/24.04 provisioning for Laravel applications.
BANNER
    printf '%b\n' "${C_RESET}"
}

# ------------------------------------------------------------------------------
# Reporting — عرض النتائج والملخص النهائي
# ------------------------------------------------------------------------------

print_results_table() {
    echo ""
    printf '%b\n' "${C_BOLD}Results:${C_RESET}"
    local i mark status
    for i in "${!STEP_FILES[@]}"; do
        status="${STEP_STATUS[$i]:--}"
        case "$status" in
            ok)     mark="${C_GREEN}[done]${C_RESET}" ;;
            FAILED) mark="${C_RED}[FAIL]${C_RESET}" ;;
            *)      mark="${C_YELLOW}[skip]${C_RESET}" ;;
        esac
        printf '%b %2d. %s\n' "$mark" "$((i + 1))" "${STEP_TITLES[$i]}"
    done
}

print_summary() {
    local domain project_path php_version db_name db_user db_pass ssl_status firewall_status queue workers program

    domain="$(get_config DOMAIN "-")"
    project_path="$(get_config PROJECT_PATH "-")"
    php_version="$(get_config PHP_VERSION "-")"
    db_name="$(get_config DB_NAME "-")"
    db_user="$(get_config DB_USER "-")"
    db_pass="$(get_config DB_PASSWORD "")"
    ssl_status="$(get_config SSL_STATUS "not configured")"
    firewall_status="$(get_config FIREWALL_STATUS "pending")"
    queue="$(get_config QUEUE_NAME "-")"
    workers="$(get_config NUM_WORKERS "-")"
    program="$(get_config PROGRAM_NAME "-")"

    local line="${C_CYAN}${C_BOLD}--------------------------------------------------------------${C_RESET}"
    echo ""
    printf '%b\n' "$line"
    printf '%b\n' "${C_BOLD} SERVER SETUP SUMMARY${C_RESET}"
    printf '%b\n' "$line"
    printf '%b\n' " Domain          : ${domain}"
    printf '%b\n' " Project path    : ${project_path}"
    printf '%b\n' " PHP version     : ${php_version}"
    printf '%b\n' " Database name   : ${db_name}"
    printf '%b\n' " Database user   : ${db_user}"
    if [[ -n "$db_pass" ]]; then
        printf '%b\n' " Database pass   : ${db_pass}"
        printf '%b\n' " Credentials file: ${CONFIG_FILE} (+ /root/laravel-db.env)"
    else
        printf '%b\n' " Database pass   : (step 4 not run yet)"
    fi
    printf '%b\n' " Redis           : localhost-only, hardened (FLUSHALL disabled)"
    printf '%b\n' " Queue workers   : ${program} (${workers}x) consuming queues: ${queue}"
    printf '%b\n' " SSL             : ${ssl_status}"
    printf '%b\n' " Firewall (UFW)  : ${firewall_status}"
    printf '%b\n' "$line"

    if [[ "$ssl_status" == "skipped" || "$ssl_status" == "not configured" ]]; then
        printf '%b\n' "${C_YELLOW} Next: point DNS to this server, then: sudo bash scripts/07-configure-ssl.sh${C_RESET}"
    fi
    if [[ "$firewall_status" != "enabled" ]]; then
        printf '%b\n' "${C_YELLOW} Next: enable the firewall when ready: sudo ufw enable${C_RESET}"
    fi
    printf '%b\n' "${C_YELLOW} Secrets live in ${CONFIG_FILE} (chmod 600, git-ignored). Keep a copy safely.${C_RESET}"
}

main "$@"
