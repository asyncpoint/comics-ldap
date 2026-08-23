#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
source "${SCRIPT_DIR}/.env"
set +a

: "${LDAP_URL:?LDAP_URL is required in .env}"
: "${LDAP_BASE_DN:?LDAP_BASE_DN is required in .env}"
: "${LDAP_ADMIN_DN:?LDAP_ADMIN_DN is required in .env}"
: "${LDAP_ADMIN_PW:?LDAP_ADMIN_PW is required in .env}"
: "${LDAP_USER_PASSWORD:?LDAP_USER_PASSWORD is required in .env}"

echo "Fetching LDAP users..."

USER_DNS="$(
    ldapsearch -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -b "$LDAP_BASE_DN" \
        "(&(objectClass=inetOrgPerson)(uid=*))" dn |
        grep '^dn: ' |
        sed 's/^dn: //'
)"

[[ -n "$USER_DNS" ]] || {
    echo "ERROR: No LDAP users were found." >&2
    exit 1
}

USER_COUNT=0

while IFS= read -r user_dn; do
    [[ -z "$user_dn" ]] && continue

    echo "Updating password for: ${user_dn}"

    ldappasswd -x \
        -H "$LDAP_URL" \
        -D "$LDAP_ADMIN_DN" \
        -w "$LDAP_ADMIN_PW" \
        -s "$LDAP_USER_PASSWORD" \
        "$user_dn"

    echo "SUCCESS: ${user_dn}"
    USER_COUNT=$((USER_COUNT + 1))
done <<< "$USER_DNS"

echo
echo "Password update complete."
echo "Users updated: ${USER_COUNT}"
