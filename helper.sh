#!/usr/bin/env bash

log() {
    echo
    echo "============================================================"
    echo "$*"
    echo "============================================================"
}

success() {
    echo "SUCCESS: $*"
}

error() {
    echo "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

require_file() {
    [[ -f "$1" ]] || error "Required file does not exist: $1"
}

require_env_var() {
    [[ -n "${!1:-}" ]] || error "Required environment variable is not set: $1"
}

extract_user_dns() {
    grep '^dn: uid=' "$1" | sed 's/^dn: //' | sort -u
}

extract_group_dn() {
    grep '^dn: cn=' "$1" | head -n 1 | sed 's/^dn: //'
}

extract_group_members() {
    grep '^member: ' "$1" | sed 's/^member: //' | sort -u
}

ldap_ready() {
    ldapwhoami -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" >/dev/null 2>&1
}

wait_for_ldap() {
    local max_attempts="${1:-60}"
    local delay="${2:-2}"
    local attempt

    log "Waiting for OpenLDAP..."

    for attempt in $(seq 1 "$max_attempts"); do
        if ldap_ready; then
            success "LDAP is ready."
            return 0
        fi

        echo "Waiting for LDAP... ${attempt}/${max_attempts}"
        sleep "$delay"
    done

    docker compose -f "$COMPOSE_FILE" logs openldap || true
    error "LDAP did not become ready."
}

verify_base_dn() {
    log "Verifying LDAP base DN: ${LDAP_BASE_DN}"

    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$LDAP_BASE_DN" \
        -s base \
        "(objectClass=*)" >/dev/null

    success "LDAP base DN verified."
}

add_ldif() {
    local ldif_file="$1"
    local description="$2"

    log "$ldif_file - $description"

    ldapadd -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -f "$ldif_file"

    success "$description"
}

verify_ou() {
    local ou_dn="$1"

    log "Verifying OU: ${ou_dn}"

    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$ou_dn" \
        -s base \
        -LLL \
        "(objectClass=organizationalUnit)" dn |
        grep -Fx "dn: ${ou_dn}" >/dev/null ||
        error "OU was not found: ${ou_dn}"

    success "OU verified: ${ou_dn}"
}

get_user_count() {
    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$LDAP_BASE_DN" \
        -LLL \
        "(&(objectClass=inetOrgPerson)(uid=*))" uid |
        grep '^uid:' |
        wc -l |
        tr -d ' '
}

verify_user_count() {
    local expected_count="$1"
    local actual_count

    log "Verifying total user count..."
    actual_count="$(get_user_count)"

    echo "Expected users: ${expected_count}"
    echo "Actual users:   ${actual_count}"

    [[ "$actual_count" -eq "$expected_count" ]] ||
        error "User count mismatch."

    success "User count verified."
}

verify_user() {
    local user_dn="$1"

    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$user_dn" \
        -s base \
        -LLL \
        "(objectClass=inetOrgPerson)" dn |
        grep -Fx "dn: ${user_dn}" >/dev/null ||
        error "User was not found: ${user_dn}"
}

verify_all_users() {
    local user_dns="$1"
    local user_dn

    log "Verifying all users..."

    while IFS= read -r user_dn; do
        [[ -z "$user_dn" ]] && continue
        verify_user "$user_dn"
        echo "Verified: ${user_dn}"
    done <<< "$user_dns"

    success "All users verified."
}

verify_user_password() {
    ldapwhoami -x \
        -H "$LDAP_URL" \
        -D "$1" \
        -w "$LDAP_USER_PASSWORD" >/dev/null 2>&1
}

verify_all_user_passwords() {
    local user_dns="$1"
    local user_dn
    local failures=0

    log "Verifying user passwords..."

    while IFS= read -r user_dn; do
        [[ -z "$user_dn" ]] && continue

        printf "Testing %s ... " "$user_dn"

        if verify_user_password "$user_dn"; then
            echo "PASS"
        else
            echo "FAIL"
            failures=$((failures + 1))
        fi
    done <<< "$user_dns"

    [[ "$failures" -eq 0 ]] ||
        error "${failures} user password verification(s) failed."

    success "All user passwords verified."
}

get_group_members() {
    local group_dn="$1"

    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$group_dn" \
        -s base \
        -LLL \
        "(objectClass=groupOfNames)" member |
        grep '^member: ' |
        sed 's/^member: //' |
        sort -u
}

verify_group() {
    local group_ldif="$1"
    local group_name="$2"
    local group_dn expected_members actual_members expected_count actual_count member_dn

    log "Verifying group: ${group_name}"

    group_dn="$(extract_group_dn "$group_ldif")"
    [[ -n "$group_dn" ]] ||
        error "Could not determine group DN from: ${group_ldif}"

    expected_members="$(extract_group_members "$group_ldif")"
    actual_members="$(get_group_members "$group_dn")"

    expected_count="$(printf '%s\n' "$expected_members" | sed '/^$/d' | wc -l | tr -d ' ')"
    actual_count="$(printf '%s\n' "$actual_members" | sed '/^$/d' | wc -l | tr -d ' ')"

    echo "Group DN: ${group_dn}"
    echo "Expected members: ${expected_count}"
    echo "Actual members:   ${actual_count}"

    [[ "$expected_count" -eq "$actual_count" ]] ||
        error "${group_name}: member count mismatch."

    diff -u \
        <(printf '%s\n' "$expected_members") \
        <(printf '%s\n' "$actual_members") ||
        error "${group_name}: membership mismatch."

    while IFS= read -r member_dn; do
        [[ -z "$member_dn" ]] && continue
        verify_user "$member_dn"
    done <<< "$actual_members"

    success "${group_name} group verified."
}

get_ou_count() {
    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$LDAP_BASE_DN" \
        -LLL \
        "(objectClass=organizationalUnit)" dn |
        grep '^dn:' |
        wc -l |
        tr -d ' '
}

get_group_count() {
    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$LDAP_BASE_DN" \
        -LLL \
        "(objectClass=groupOfNames)" cn |
        grep '^cn:' |
        wc -l |
        tr -d ' '
}

print_final_summary() {
    local ou_count user_count group_count

    ou_count="$(get_ou_count)"
    user_count="$(get_user_count)"
    group_count="$(get_group_count)"

    echo
    echo "============================================================"
    echo " FINAL LDAP DIRECTORY"
    echo "============================================================"
    echo "Base DN: ${LDAP_BASE_DN}"
    echo "OUs:     ${ou_count}"
    echo "Users:   ${user_count}"
    echo "Groups:  ${group_count}"
    echo
}
