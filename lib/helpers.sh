#!/usr/bin/env bash
# ==============================================================================
# lib/helpers.sh — المكتبة المشتركة لمشروع laravel-server-setup
#
# تحتوي على: الألوان، دوال التسجيل (logging)، فحص صلاحيات root ونظام التشغيل،
# أسئلة المستخدم التفاعلية، توليد كلمات السر الآمنة، ومخزن إعدادات بسيط
# يعتمد على ملف .setup-config في جذر المشروع.
#
# Shared helper library for laravel-server-setup: colors, logging functions,
# privilege/OS checks, interactive prompts, secure password generation and a
# tiny key=value config store backed by the .setup-config file at the project
# root. Every setup script sources this file, so it must stay side-effect free
# apart from defining constants and functions.
# ==============================================================================

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LIB_DIR

PROJECT_ROOT="$(dirname "$LIB_DIR")"
readonly PROJECT_ROOT

# Central store for values shared between steps (domain, DB creds, ...).
# It is git-ignored and always created with 0600 permissions because it holds
# generated secrets.
CONFIG_FILE="$PROJECT_ROOT/.setup-config"
readonly CONFIG_FILE

# ------------------------------------------------------------------------------
# Colors — ألوان الإخراج (تُستخدم فقط عند التشغيل في طرفية تفاعلية)
# Colors are only emitted on interactive terminals so logs stay readable when
# redirected to files or CI output.
# ------------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly C_RESET=$'\e[0m'
    readonly C_BOLD=$'\e[1m'
    readonly C_RED=$'\e[0;31m'
    readonly C_GREEN=$'\e[0;32m'
    readonly C_YELLOW=$'\e[1;33m'
    readonly C_BLUE=$'\e[0;34m'
    readonly C_CYAN=$'\e[0;36m'
else
    readonly C_RESET='' C_BOLD='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

# ------------------------------------------------------------------------------
# Logging — دوال تسجيل موحّدة الشكل في كل السكريبتات
# ------------------------------------------------------------------------------

# %b interprets the escape sequences stored inside our color variables.
log_info()  { printf '%b\n' "${C_BLUE}[INFO]${C_RESET} $*"; }
log_ok()    { printf '%b\n' "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()  { printf '%b\n' "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_error() { printf '%b\n' "${C_RED}[FAIL]${C_RESET} $*" >&2; }

# Prominent section header so users can follow multi-step progress.
log_step()  { printf '\n%b\n' "${C_BOLD}${C_CYAN}==> $*${C_RESET}"; }

# Print an error message and exit with a non-zero status.
# Every fatal path in every script goes through here to keep messages uniform.
die() {
    log_error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# System checks — فحص الصلاحيات ونظام التشغيل
# ------------------------------------------------------------------------------

# All setup scripts mutate system state, so they must run as root.
check_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "This script must be run as root. Try: sudo bash install.sh"
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Only Ubuntu 22.04 LTS and 24.04 LTS are supported/tested; failing fast with a
# clear message beats half-installing packages on the wrong distro release.
check_os() {
    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release - is this really a Debian-based system?"
    fi

    # shellcheck disable=SC1091  # provided by the OS at runtime
    . /etc/os-release

    if [[ "${ID:-unknown}" != "ubuntu" ]]; then
        die "Unsupported distribution '${ID:-unknown}'. This project targets Ubuntu 22.04/24.04 only."
    fi

    case "${VERSION_ID:-unknown}" in
        22.04|24.04) log_ok "Detected Ubuntu ${VERSION_ID} (supported)." ;;
        *)           die "Unsupported Ubuntu version '${VERSION_ID:-unknown}'. Use 22.04 or 24.04." ;;
    esac
}

# ------------------------------------------------------------------------------
# Interactive prompts — أسئلة المستخدم
#
# read -p prints its prompt to stderr, so these helpers work both interactively
# and inside command substitutions without polluting captured stdout.
# ------------------------------------------------------------------------------

# ask "Question" [default] -> echoes the answer (or the default when empty).
ask() {
    local prompt="$1"
    local default="${2:-}"
    local reply=""
    local shown="$prompt"

    if [[ -n "$default" ]]; then
        shown="${prompt} [${default}]"
    fi

    if ! read -r -p "$(printf '%b' "${C_CYAN}? ${shown}:${C_RESET} ")" reply; then
        # EOF (piped/closed stdin) should abort loudly instead of continuing empty.
        die "Could not read user input."
    fi
    printf '%s\n' "${reply:-$default}"
}

# Same as ask(), but typed characters are hidden - used for passwords/tokens.
ask_secret() {
    local prompt="$1"
    local reply=""

    if ! read -r -s -p "$(printf '%b' "${C_CYAN}? ${prompt}:${C_RESET} ")" reply; then
        die "Could not read user input."
    fi
    printf '\n'
    printf '%s\n' "$reply"
}

# confirm "Question" -> returns 0 for yes, 1 for anything else.
confirm() {
    local prompt="$1"
    local reply=""
    if ! read -r -p "$(printf '%b' "${C_CYAN}? ${prompt} [y/N]:${C_RESET} ")" reply; then
        return 1
    fi
    [[ "$reply" =~ ^[Yy]$ ]]
}

# ------------------------------------------------------------------------------
# Secrets — توليد كلمات سر عشوائية آمنة
# ------------------------------------------------------------------------------

# generate_password [length] -> alphanumeric password (default 24 chars).
# Letters/digits only so results embed safely (unquoted) in SQL, nginx configs
# and Laravel .env files without escaping headaches.
generate_password() {
    local length="${1:-24}"

    if (( length < 8 || length > 64 )); then
        die "generate_password: length must be between 8 and 64."
    fi

    if command_exists openssl; then
        # base64 of 3x bytes leaves enough alphanumeric chars after filtering;
        # cut consumes input until EOF so there are no SIGPIPE exit-code
        # surprises under "set -o pipefail".
        openssl rand -base64 $((length * 3)) | tr -dc 'A-Za-z0-9' | cut -c1-"$length"
    else
        # Fallback for minimal systems without openssl installed yet.
        dd if=/dev/urandom bs=1024 count=16 2>/dev/null \
            | tr -dc 'A-Za-z0-9' | cut -c1-"$length"
    fi
}

# ------------------------------------------------------------------------------
# Config store — حفظ وقراءة القيم المشتركة بين السكريبتات (.setup-config)
# ------------------------------------------------------------------------------

# get_config KEY [default] -> prints stored value or the given default.
get_config() {
    local key="$1"
    local default="${2:-}"
    local value=""

    if [[ -f "$CONFIG_FILE" ]]; then
        value="$(grep -E "^${key}=" "$CONFIG_FILE" | tail -n1 | cut -d'=' -f2- || true)"
    fi
    printf '%s' "${value:-$default}"
}

# set_config KEY VALUE -> upsert a key into the config store.
set_config() {
    local key="$1"
    local value="$2"

    touch "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"

    # Drop any previous entry for this key, then append the fresh value so the
    # newest assignment always wins.
    grep -vE "^${key}=" "$CONFIG_FILE" >"${CONFIG_FILE}.tmp" || true
    mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    printf '%s=%s\n' "$key" "$value" >>"$CONFIG_FILE"
}
