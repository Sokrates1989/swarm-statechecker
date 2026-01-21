#!/bin/bash
# ==============================================================================
# backup_integration.sh - Backup network integration helpers
# ==============================================================================
# Module: backup_integration.sh
# Description:
#   Integrates the swarm-statechecker MySQL service with the shared backup-net
#   overlay used by the Swarm Backup-Restore stack.
# ==============================================================================

# ------------------------------------------------------------------------------
# Detect a deployed Swarm Backup-Restore stack using known stack/image patterns.
#
# Outputs:
#   "<stack_name>|<source>" where source is "stack" or "image".
# Returns:
#   0 if detected, 1 otherwise
# ------------------------------------------------------------------------------
_detect_backup_restore_stack() {
    local default_stack="backup-restore"
    local default_api_image="sokrates1989/backup-restore"
    local default_web_image="sokrates1989/backup-restore-web"

    local stack_name=""
    local source=""

    if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "${default_stack}"; then
        stack_name="${default_stack}"
        source="stack"
    fi

    if [ -z "$stack_name" ]; then
        local service_stack
        service_stack=$(docker service ls --format '{{.Name}} {{.Image}}' 2>/dev/null | \
            awk -v api_image="$default_api_image" -v web_image="$default_web_image" '\
                $2 ~ api_image || $2 ~ web_image { print $1; exit }' | \
            awk -F_ '{print $1}')
        if [ -n "$service_stack" ]; then
            stack_name="$service_stack"
            source="image"
        fi
    fi

    if [ -n "$stack_name" ]; then
        echo "${stack_name}|${source}"
        return 0
    fi

    return 1
}

# ------------------------------------------------------------------------------
# Print guidance for the Swarm Backup-Restore integration and detection info.
# ------------------------------------------------------------------------------
_print_backup_restore_guidance() {
    local default_stack="backup-restore"
    local default_api_image="sokrates1989/backup-restore"
    local default_web_image="sokrates1989/backup-restore-web"

    echo "[INFO] This backup network is used by the Swarm Backup-Restore deployment."
    echo "       Use it with the 'swarm-backup-restore' deployment repo (which deploys the"
    echo "       backup-restore API/Web images from the 'backup-restore' project)."

    local detection
    detection=$(_detect_backup_restore_stack 2>/dev/null || true)
    local detected_stack="${detection%%|*}"
    local detected_source="${detection##*|}"

    if [ -n "$detected_stack" ]; then
        if [ "$detected_source" = "stack" ]; then
            echo "[OK] Detected backup-restore stack: ${detected_stack} (by stack name)."
        else
            echo "[OK] Detected backup-restore stack: ${detected_stack} (by image match)."
        fi
    else
        echo "[WARN] No backup-restore stack detected yet."
        echo "       Default stack name: ${default_stack}"
        echo "       Default images: ${default_api_image}, ${default_web_image}"
        echo "       Deploy it from the swarm-backup-restore repo (quick-start.sh)."
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# Prompt for yes/no confirmation.
#
# Arguments:
#   $1 = prompt text
#   $2 = default value (Y/N)
#
# Returns:
#   0 for yes, 1 for no
# ------------------------------------------------------------------------------
_prompt_yes_no() {
    local prompt="$1"
    local default_value="${2:-N}"
    local response

    read_prompt "${prompt} [${default_value}]: " response
    response="${response:-$default_value}"

    case "$response" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# ------------------------------------------------------------------------------
# Prompt for the central backup overlay network.
# The backup network is expected to be created/managed by the swarm-backup-restore stack.
# This implementation enforces the fixed network name "backup-net".
# Returns: "backup-net" on success, non-zero exit on failure
# ------------------------------------------------------------------------------
prompt_backup_network() {
    local expected_network="backup-net"

    while true; do
        echo "" >&2
        echo "[CONFIG] Backup Overlay Network (overlay)" >&2
        echo "---------------------------------------" >&2
        echo "The backup network must be created by the Swarm Backup-Restore stack." >&2
        echo "Expected network name: '${expected_network}' (recommended)" >&2
        echo "" >&2

        local networks
        IFS=$'\n' read -r -d '' -a networks < <(docker network ls --filter driver=overlay --format "{{.Name}}" 2>/dev/null && printf '\0')

        if [ ${#networks[@]} -eq 0 ]; then
            echo "[WARN] No overlay networks found." >&2
            echo "       Deploy Swarm Backup-Restore first so it can create '${expected_network}'." >&2
            return 1
        fi

        local detected_idx=""
        local i=0
        for net in "${networks[@]}"; do
            if [ "$net" = "$expected_network" ]; then
                detected_idx="$((i+1))"
                break
            fi
            i=$((i+1))
        done

        if [ -z "$detected_idx" ]; then
            echo "[WARN] Expected network '${expected_network}' not found." >&2
            echo "       Run: swarm-backup-restore/quick-start.sh → Deploy / Update stack" >&2
            echo "" >&2
        else
            echo "✅ Auto-detected '${expected_network}' (recommended)" >&2
        fi

        local n=1
        for net in "${networks[@]}"; do
            if [ "$net" = "$expected_network" ]; then
                echo "$n) ✅ $net (recommended)" >&2
            else
                echo "$n) $net" >&2
            fi
            n=$((n+1))
        done

        echo "" >&2
        if [ -z "$detected_idx" ]; then
            local retry
            read_prompt "Retry after creating '${expected_network}'? (y/N): " retry
            if [[ ! "$retry" =~ ^[Yy]$ ]]; then
                return 1
            fi
            continue
        fi

        local selection
        read_prompt "Backup network (number) [${detected_idx}]: " selection
        selection="${selection:-${detected_idx}}"

        if [[ ! "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#networks[@]} ]; then
            echo "[ERROR] Invalid selection" >&2
            continue
        fi

        local chosen="${networks[$((selection-1))]}"
        if [ "$chosen" != "$expected_network" ]; then
            echo "[ERROR] Only '${expected_network}' is supported. Selected: '${chosen}'" >&2
            continue
        fi

        echo "$expected_network"
        return 0
    done
}

# ------------------------------------------------------------------------------
# Verify the local DB service is attached to the backup network after deploy.
#
# Arguments:
#   $1 = stack_name   → Docker stack name
#   $2 = network_name → Backup network name (default: backup-net)
#   $3 = retries      → Number of retries (default: 6)
#   $4 = wait_seconds → Wait between retries (default: 5)
#
# Returns:
#   0 if attached, 1 otherwise
# ------------------------------------------------------------------------------
_verify_db_backup_network_attachment() {
    local stack_name="$1"
    local network_name="${2:-backup-net}"
    local retries="${3:-6}"
    local wait_seconds="${4:-5}"
    local db_service="${stack_name}_db"

    if ! docker service inspect "$db_service" >/dev/null 2>&1; then
        echo "[WARN] Swarm service '$db_service' not found. Skipping backup network check."
        return 1
    fi

    local network_id
    network_id=$(docker network inspect "$network_name" --format '{{.ID}}' 2>/dev/null)
    if [ -z "$network_id" ]; then
        echo "[WARN] Network '$network_name' not found. Skipping backup network check."
        return 1
    fi

    local attempt=1
    while [ "$attempt" -le "$retries" ]; do
        local service_networks
        service_networks=$(docker service inspect "$db_service" --format '{{range .Spec.TaskTemplate.Networks}}{{.Target}} {{end}}' 2>/dev/null)
        if echo " $service_networks " | grep -q " ${network_id} "; then
            echo "[OK] Database service '${db_service}' is attached to '${network_name}'."
            return 0
        fi
        echo "[WAIT] '${network_name}' attachment not confirmed yet (attempt ${attempt}/${retries})."
        sleep "$wait_seconds"
        attempt=$((attempt + 1))
    done

    echo "[WARN] Database service '${db_service}' is not attached to '${network_name}'."
    echo "       Check: docker service inspect ${db_service} --format '{{json .Spec.TaskTemplate.Networks}}'"
    return 1
}

# ------------------------------------------------------------------------------
# Print Backup-Restore UI connection details for the local database service.
#
# Arguments:
#   $1 = stack_name   → Docker stack name
#   $2 = db_name      → Database name
#   $3 = db_user      → Database user
#   $4 = network_name → Backup network name (default: backup-net)
#   $5 = db_type      → Backup-Restore DB_TYPE value (default: mysql)
# ------------------------------------------------------------------------------
_print_backup_restore_connection_info() {
    local stack_name="$1"
    local db_name="$2"
    local db_user="$3"
    local network_name="${4:-backup-net}"
    local db_type="${5:-mysql}"

    echo "Backup-Restore UI connection details:"
    echo "  - Network:      ${network_name}"
    echo "  - DB Type:      ${db_type}"
    echo "  - DB Host:      ${stack_name}_db"
    echo "  - DB Port:      3306"
    echo "  - Database:     ${db_name}"
    echo "  - Username:     ${db_user}"
    echo "  - Password:     <DB user password>"
    echo ""
}

# ------------------------------------------------------------------------------
# Print MySQL-specific guidance for backup/restore credentials.
#
# Arguments:
#   $1 = db_name → Database name
#   $2 = db_user → Default database user
# ------------------------------------------------------------------------------
_print_backup_restore_security_guidance() {
    local db_name="$1"
    local db_user="$2"
    local backup_user="statechecker_backup"

    echo "Security hardening (recommended):"
    local net_opts
    net_opts=$(docker network inspect backup-net --format '{{json .Options}}' 2>/dev/null || true)
    if echo "$net_opts" | grep -qi 'encrypted'; then
        echo "  1) [OK] Network 'backup-net' appears to be encrypted (overlay)"
    else
        echo "  1) [WARN] Network 'backup-net' does not appear to be encrypted."
        echo "           For highest security, create it with:"
        echo "           docker network rm backup-net  # only if no stacks are attached"
        echo "           docker network create --driver overlay --opt encrypted backup-net"
    fi

    echo "  2) Choose credentials for Backup-Restore (single user for backup + restore)."
    echo "     Simplest: reuse the DB owner '${db_user}' (works for backup + restore)."
    echo "     Alternative: create '${backup_user}' with backup-friendly permissions:"
    echo "       CREATE USER '${backup_user}'@'%' IDENTIFIED BY '<GENERATE_STRONG_PASSWORD>';"
    echo "       GRANT SELECT, SHOW VIEW, LOCK TABLES, EVENT, TRIGGER ON \\`${db_name}\\`.* TO '${backup_user}'@'%';"
    echo "       FLUSH PRIVILEGES;"

    echo "  3) Credential scope"
    echo "     - Backup-Restore uses one credential for backup + restore."
    echo "     - Restores require owner/DDL permissions (read-only roles will fail)."
    echo "     - Protect access via secrets + network isolation (backup-net)."
    echo ""
}

# ------------------------------------------------------------------------------
# Show Backup-Restore UI connection details based on current .env values.
#
# Returns:
#   0 if details printed, 1 otherwise
# ------------------------------------------------------------------------------
show_backup_restore_connection_info() {
    local env_file="$(pwd)/.env"
    if [ ! -f "$env_file" ]; then
        echo "[ERROR] .env not found. Run the setup wizard first."
        return 1
    fi

    if ! grep -Eq '^ENABLE_BACKUP_NETWORK="?true"?$' "$env_file" 2>/dev/null; then
        echo "[WARN] Backup integration is not enabled. Info below assumes 'backup-net' is attached."
    fi

    local stack_name
    stack_name=$(grep -E '^STACK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    stack_name="${stack_name:-statechecker}"
    local db_name
    db_name=$(grep -E '^DB_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    db_name="${db_name:-state_checker}"
    local db_user
    db_user=$(grep -E '^DB_USER=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    db_user="${db_user:-state_checker}"
    local db_type
    db_type=$(grep -E '^DB_TYPE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    db_type="${db_type:-mysql}"

    _print_backup_restore_connection_info "$stack_name" "$db_name" "$db_user" "backup-net" "$db_type"
}

# ------------------------------------------------------------------------------
# Enable backup network integration and optionally redeploy the stack.
# ------------------------------------------------------------------------------
handle_setup_backup_integration() {
    local env_file="$(pwd)/.env"
    local stack_file="$(pwd)/swarm-stack.yml"

    if [ ! -f "$env_file" ]; then
        echo "[ERROR] .env not found. Run the setup wizard first."
        return 1
    fi

    if [ ! -f "$stack_file" ]; then
        echo "[ERROR] swarm-stack.yml not found. Run the setup wizard first."
        return 1
    fi

    echo ""
    echo "[BACKUP] Central Backup Integration"
    echo "=================================="
    echo ""

    _print_backup_restore_guidance

    if ! prompt_backup_network >/dev/null; then
        echo "[ERROR] Cannot enable backup integration because 'backup-net' is missing."
        echo "        Deploy the Swarm Backup-Restore stack first so it can create the network."
        return 1
    fi

    update_env_values "$env_file" "ENABLE_BACKUP_NETWORK" "true"

    if ! update_stack_backup_network "$stack_file" "true"; then
        echo "[ERROR] Failed to update backup network integration in swarm-stack.yml"
        return 1
    fi

    echo ""
    echo "[OK] Updated .env and swarm-stack.yml"
    echo ""

    local stack_name
    stack_name=$(grep -E '^STACK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    stack_name="${stack_name:-statechecker}"
    local db_name
    db_name=$(grep -E '^DB_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    db_name="${db_name:-state_checker}"
    local db_user
    db_user=$(grep -E '^DB_USER=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    db_user="${db_user:-state_checker}"
    local db_type
    db_type=$(grep -E '^DB_TYPE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    db_type="${db_type:-mysql}"

    _print_backup_restore_security_guidance "$db_name" "$db_user"
    _print_backup_restore_connection_info "$stack_name" "$db_name" "$db_user" "backup-net" "$db_type"

    if _prompt_yes_no "Redeploy the stack now to apply the backup network?" "Y"; then
        echo ""
        echo "[DEPLOY] Redeploying to Docker Swarm..."
        echo ""
        if ! _ensure_data_dirs_before_deploy; then
            echo "[ERROR] Deployment aborted due to data directory preparation failure."
            return 1
        fi
        if ! deploy_stack; then
            echo "[ERROR] Deployment failed"
            return 1
        fi
        echo ""
        echo "[OK] Redeploy triggered. Monitor with: docker stack services ${stack_name}"
        _verify_db_backup_network_attachment "$stack_name" "backup-net"
        _print_backup_restore_connection_info "$stack_name" "$db_name" "$db_user" "backup-net" "$db_type"
    else
        echo "[INFO] Redeploy required: use 'Deploy stack' after enabling backup integration."
    fi
}
