#!/usr/bin/env bash
# ==============================================================================
# 04-install-mysql.sh — تثبيت MySQL وتأمينه وإنشاء قاعدة بيانات للمشروع
#
# يقوم بما يلي:
#   1) تثبيت MySQL Server وتشغيله
#   2) تنفيذ خطوات mysql_secure_installation تلقائيًا
#   3) إنشاء قاعدة بيانات ومستخدم مخصصين للمشروع مع كلمة سر عشوائية آمنة
#      (أو كلمة سر يدوية يحددها المستخدم)
#   4) حفظ البيانات في .setup-config وفي ملف Laravel env جاهز للنسخ
#
# Usage: sudo bash scripts/04-install-mysql.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/../lib/helpers.sh"

readonly CREDENTIALS_FILE="/root/laravel-db.env"

main() {
    check_root
    check_os

    log_step "Step 4/9: MySQL server installation"

    install_mysql
    secure_installation
    create_app_database
    write_credentials_file

    echo ""
    log_ok "MySQL is ready. Credentials saved to:"
    log_ok "  - ${CONFIG_FILE}          (internal setup state)"
    log_ok "  - ${CREDENTIALS_FILE}     (Laravel .env snippet)"
}

install_mysql() {
    if command_exists mysqld; then
        log_ok "MySQL already installed."
    else
        log_info "Installing MySQL server (may take a few minutes)..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
        log_ok "MySQL installed."
    fi

    systemctl enable --now mysql >/dev/null 2>&1 || true
    systemctl is-active --quiet mysql || die "MySQL service failed to start. Check: journalctl -u mysql"
}

secure_installation() {
    log_info "Applying secure-installation hardening..."

    # Equivalent of the interactive mysql_secure_installation answers:
    #   - remove anonymous accounts
    #   - drop the test database and its privileges
    #   - disallow root login from anything except local sockets
    # We intentionally do NOT set a root password: Ubuntu ships root with
    # auth_socket, meaning only system root (sudo) can use it - stronger than
    # a password that could leak or be brute-forced over TCP.
    mysql <<'SQL'
DELETE FROM mysql.user WHERE User = '';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db IN ('test', 'test\_%');
DELETE FROM mysql.user WHERE User = 'root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
FLUSH PRIVILEGES;
SQL
    log_ok "Anonymous users, test database and remote root removed."
}

create_app_database() {
    echo ""
    log_info "Creating the application database and user."

    local db_name db_user db_password user_exists

    db_name="$(get_config DB_NAME "laravel")"
    db_name="$(ask "Database name" "$db_name")"
    validate_identifier "$db_name" "database name"

    db_user="$(get_config DB_USER "laravel_user")"
    db_user="$(ask "Database user" "$db_user")"
    validate_identifier "$db_user" "database user"

    echo ""
    log_warn "Leave the next prompt empty to auto-generate a strong password."
    db_password="$(ask_secret "Database password (empty = generate)")"
    if [[ -z "$db_password" ]]; then
        db_password="$(generate_password 28)"
        log_info "Generated password automatically."
    elif ! printf '%s' "$db_password" | grep -Eq '^[A-Za-z0-9_-]{12,64}$'; then
        die "Password must be 12-64 chars using only letters, digits, _ or - (safe for SQL/.env embedding)."
    fi

    # Detect an existing user purely to give honest feedback about what happened.
    user_exists="$(mysql -NBe "SELECT COUNT(*) FROM mysql.user WHERE User='${db_user}' AND Host='localhost';")"
    if [[ "$user_exists" != "0" ]]; then
        # Re-running the setup rotates the password on purpose: the operator
        # gets fresh credentials in one predictable place instead of a stale
        # mismatch between MySQL and Laravel's .env.
        log_warn "User '${db_user}' already exists - its password will be rotated."
    fi

    # Identifiers were validated as [A-Za-z0-9_]+ above, so they are safe to
    # interpolate without quoting; the password charset was validated too.
    mysql <<SQL
CREATE DATABASE IF NOT EXISTS ${db_name} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_password}';
GRANT ALL PRIVILEGES ON ${db_name}.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
SQL

    set_config DB_NAME "$db_name"
    set_config DB_USER "$db_user"
    set_config DB_PASSWORD "$db_password"

    echo ""
    log_ok "Database '${db_name}' created."
    log_ok "User '${db_user}'@'localhost' granted full privileges on it."
    log_ok "Password: ${db_password}"
}

write_credentials_file() {
    cat >"$CREDENTIALS_FILE" <<EOF
# Paste these lines into your Laravel application's .env file.
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=$(get_config DB_NAME "")
DB_USERNAME=$(get_config DB_USER "")
DB_PASSWORD=$(get_config DB_PASSWORD "")
EOF
    chmod 600 "$CREDENTIALS_FILE"
    log_ok "Laravel env snippet written to ${CREDENTIALS_FILE} (chmod 600)."
}

validate_identifier() {
    local value="$1"
    local label="$2"
    if ! printf '%s' "$value" | grep -Eq '^[A-Za-z0-9_]{1,32}$'; then
        die "${label} must be 1-32 characters: letters, digits or underscore only."
    fi
}

main "$@"
