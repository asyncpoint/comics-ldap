#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMPOSE_FILE="${SCRIPT_DIR}/compose.yaml"
PASSWORD_SCRIPT="${SCRIPT_DIR}/reset-password.sh"

LDIF_DIR="${SCRIPT_DIR}/ldif"

DC_USERS_LDIF="${LDIF_DIR}/01-dc-users.ldif"
MARVEL_USERS_LDIF="${LDIF_DIR}/02-marvel-users.ldif"

# Load the same .env file used by Docker Compose.
set -a
source "${SCRIPT_DIR}/.env"
set +a

source "${SCRIPT_DIR}/helper.sh"

LDAP_USER_BASE="ou=users,${LDAP_BASE_DN}"

build_failed() {
    echo
    echo "============================================================"
    echo " BUILD FAILED"
    echo "============================================================"
    echo "The OpenLDAP container has been left running for inspection."
    echo "Container logs:"
    echo "  docker compose -f ${COMPOSE_FILE} logs openldap"
}

trap build_failed ERR

#-----------------------------------------
log "Step 1/12 - Validating prerequisites"

for command in docker ldapsearch ldapadd ldapwhoami ldappasswd diff; do
    require_command "$command"
done

for var in \
    LDAP_URL LDAP_BASE_DN LDAP_ADMIN_DN LDAP_ADMIN_PW LDAP_USER_PASSWORD \
    IMAGE_NAME IMAGE_VERSION CONTAINER_NAME \
    OPENLDAP_BOOTSTRAP_ROOT_PASSWORD_HASHED
do
    require_env_var "$var"
done

success "All required commands and environment variables are available."

#-----------------------------------------
log "Step 2/12 - Validating project files"

for file in \
    "$COMPOSE_FILE" \
    "${SCRIPT_DIR}/.env" \
    "${SCRIPT_DIR}/helper.sh" \
    "$PASSWORD_SCRIPT"
do
    require_file "$file"
done

success "All required project files are available."

#-------------------------------------------
log "Step 3/12 - Determining expected users"

EXPECTED_USER_DNS="$(
    {
        extract_user_dns "$DC_USERS_LDIF"
        extract_user_dns "$MARVEL_USERS_LDIF"
    } | sort -u
)"

[[ -n "$EXPECTED_USER_DNS" ]] ||
    error "No users found in user LDIF files."

EXPECTED_USER_COUNT="$(
    printf '%s\n' "$EXPECTED_USER_DNS" |
    sed '/^$/d' |
    wc -l |
    tr -d ' '
)"

echo "Expected user count: ${EXPECTED_USER_COUNT}"

#--------------------------------------------------
log "Step 4/12 - Removing previous build container"

docker compose -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

success "Previous build environment removed."

#----------------------------------------
log "Step 5/12 - Starting clean OpenLDAP"

docker compose -f "$COMPOSE_FILE" up -d
wait_for_ldap

#------------------------------------
log "Step 6/12 - Verifying LDAP base"
verify_base_dn

#---------------------------------
log "Step 7/12 - Creating LDAP OU"

add_ldif "$LDIF_DIR/00-structure.ldif" "Creating Comics OU"
verify_ou "$LDAP_USER_BASE"

#------------------------------------
log "Step 8/12 - Creating LDAP users ..."

add_ldif "$DC_USERS_LDIF" "Creating DC users ..."
add_ldif "$MARVEL_USERS_LDIF" "Creating MARVEL users ..."

verify_user_count "$EXPECTED_USER_COUNT"
verify_all_users "$EXPECTED_USER_DNS"

#---------------------------------------
log "Step 9/12 - Setting user passwords"

bash "$PASSWORD_SCRIPT"
verify_all_user_passwords "$EXPECTED_USER_DNS"

#--------------------------------------
log "Step 10/12 - Creating LDAP groups"

add_ldif "$LDIF_DIR/03-groups-membership.ldif" "Adding users to their groups ..."

#--------------------------------------------
# log "Step 11/12 - Verifying group membership"

# verify_group "$AUTOBOT_GROUP_LDIF" "Autobots"
# verify_group "$DECEPTICON_GROUP_LDIF" "Decepticons"

# print_final_summary

#---------------------------------------------
log "Step 12/12 - Creating final Docker image"

# docker image rm "${IMAGE_NAME}:${IMAGE_VERSION}" >/dev/null 2>&1 || true

docker commit --pause -m "Pre-filled Comics OpenLDAP directory" \
    "$CONTAINER_NAME" \
    "${IMAGE_NAME}:${IMAGE_VERSION}"

docker tag "${IMAGE_NAME}:${IMAGE_VERSION}" "${IMAGE_NAME}:latest"

echo
echo "============================================================"
echo " BUILD SUCCESSFUL"
echo "============================================================"
echo "Created images:"
echo "  ${IMAGE_NAME}:${IMAGE_VERSION}"
echo "  ${IMAGE_NAME}:latest"
echo

docker images "$IMAGE_NAME"
