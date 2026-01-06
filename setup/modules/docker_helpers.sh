#!/bin/bash
#
# docker_helpers.sh
#
# Module for Docker-related helper functions for Swarm deployment

check_docker_swarm() {
    # check_docker_swarm
    # Verifies:
    # - Docker CLI is installed
    # - Docker daemon is running
    # - Docker Swarm mode is active
    # Returns:
    # - 0 if all checks pass
    # - 1 otherwise
    echo "🔍 Checking Docker Swarm..."
    
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker is not installed!"
        return 1
    fi

    if ! docker info &> /dev/null; then
        echo "❌ Docker daemon is not running!"
        return 1
    fi

    # Check if in swarm mode
    local swarm_status
    swarm_status=$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)
    
    if [ "$swarm_status" = "error" ]; then
        echo "❌ Docker Swarm is in an ERROR state."
        
        local err_line
        err_line=$(docker info 2>&1 | grep '^  Error:' | head -n 1)
        if [ -n "$err_line" ]; then
            echo "   $err_line"
        fi

        echo ""
        echo "Common causes:"
        echo "  - Expired Swarm TLS certificates (often after a long time or incorrect system time)"
        echo ""
        echo "Suggested fixes (choose one depending on your setup):"
        echo "  - Single-node: docker swarm leave --force  (then)  docker swarm init"
        echo "  - Multi-node: rotate CA and re-join nodes (docker swarm ca --rotate)"
        echo ""
        return 1
    fi

    if [ "$swarm_status" != "active" ]; then
        echo "❌ Docker is not in Swarm mode!"
        echo "   Run 'docker swarm init' to initialize a swarm"
        return 1
    fi

    echo "✅ Docker Swarm is active"
    return 0
}

prompt_traefik_network() {
    # prompt_traefik_network
    # Lists existing Docker overlay networks and allows selection or creation.
    # Auto-detects common Traefik network names (traefik, traefik-public, traefik_public).
    # Returns: network name string via stdout
    local default_network="${1:-traefik}"
    local network_name=""
    local network_selected=false
    
    # Get overlay networks
    local networks=()
    while IFS= read -r line; do
        [ -n "$line" ] && networks+=("$line")
    done < <(docker network ls --filter driver=overlay --format "{{.Name}}" 2>/dev/null)

    if [ ${#networks[@]} -eq 0 ]; then
        echo "" >&2
        echo "[WARN] No overlay networks found" >&2
        echo "You need a Traefik public overlay network before deploying this stack." >&2
        echo "" >&2
        if [[ -r /dev/tty ]]; then
            read -r -p "Traefik network name [$default_network]: " input_net < /dev/tty
        else
            read -r -p "Traefik network name [$default_network]: " input_net
        fi
        echo "${input_net:-$default_network}"
        return 0
    fi

    # Auto-detect common Traefik network names
    local default_selection="1"
    local detected_network=""
    local preferred_networks=("traefik-public" "traefik_public" "traefik")
    
    for preferred in "${preferred_networks[@]}"; do
        local idx=0
        for net in "${networks[@]}"; do
            if [ "$net" = "$preferred" ]; then
                detected_network="$net"
                default_selection="$((idx+1))"
                break 2
            fi
            idx=$((idx+1))
        done
    done

    if [ -n "$detected_network" ]; then
        echo "✅ Auto-detected common Traefik network: $detected_network (recommended)" >&2
    fi

    echo "" >&2
    echo "Select the Traefik public overlay network from the list below." >&2
    echo "Do NOT pick an app-specific network (such as '*_backend')." >&2
    echo "0) Enter a network name manually" >&2

    local i=1
    for net in "${networks[@]}"; do
        if [ -n "$detected_network" ] && [ "$net" = "$detected_network" ]; then
            echo "$i) ✅ $net (recommended)" >&2
        else
            echo "$i) $net" >&2
        fi
        i=$((i+1))
    done
    echo "" >&2

    local selection
    if [[ -r /dev/tty ]]; then
        read -r -p "Traefik network (number or name) [${default_selection}]: " selection < /dev/tty
    else
        read -r -p "Traefik network (number or name) [${default_selection}]: " selection
    fi
    selection="${selection:-${default_selection}}"

    # Check if it's a number
    if [[ "$selection" =~ ^[0-9]+$ ]]; then
        if [ "$selection" -eq 0 ]; then
            if [[ -r /dev/tty ]]; then
                read -r -p "Network name [$default_network]: " network_name < /dev/tty
            else
                read -r -p "Network name [$default_network]: " network_name
            fi
            echo "${network_name:-$default_network}"
            return 0
        elif [ "$selection" -ge 1 ] && [ "$selection" -le "${#networks[@]}" ]; then
            echo "${networks[$((selection-1))]}"
            return 0
        fi
    fi

    echo "$selection"
}

check_secret_exists() {
    # check_secret_exists
    # Checks whether a Docker secret exists.
    # Arguments:
    # - $1: secret name
    # Returns:
    # - 0 if secret exists
    # - 1 otherwise
    local secret_name="$1"
    if docker secret inspect "$secret_name" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

_get_stack_name_for_secret_ops() {
    # _get_stack_name_for_secret_ops
    # Determines the stack name to use for secret recreation safety checks.
    #
    # Returns:
    # - stack name string via stdout
    local stack_name="${STACK_NAME:-}"

    if [ -z "$stack_name" ] && [ -f .env ]; then
        stack_name=$(grep '^STACK_NAME=' .env 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    fi

    echo "${stack_name:-statechecker}"
}

_is_stack_running_for_secret_ops() {
    # _is_stack_running_for_secret_ops
    # Checks whether a swarm stack is currently deployed.
    #
    # Arguments:
    # - $1: stack name
    #
    # Returns:
    # - 0 if running
    # - 1 otherwise
    local stack_name="$1"
    [ -z "$stack_name" ] && return 1

    docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$stack_name"
}

_wait_for_stack_removal_for_secret_ops() {
    # _wait_for_stack_removal_for_secret_ops
    # Waits until a stack is removed (best-effort).
    #
    # Arguments:
    # - $1: stack name
    # - $2: timeout seconds (optional, default: 120)
    local stack_name="$1"
    local timeout_seconds="${2:-120}"
    local elapsed=0

    while [ $elapsed -lt "$timeout_seconds" ]; do
        if ! _is_stack_running_for_secret_ops "$stack_name"; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

_ensure_stack_removed_for_secret_recreate() {
    # _ensure_stack_removed_for_secret_recreate
    # Ensures a running stack is removed before deleting/recreating secrets.
    #
    # Arguments:
    # - $1: secret name
    # - $2: stack name
    #
    # Returns:
    # - 0 if stack is not running or was removed
    # - 1 otherwise
    local secret_name="$1"
    local stack_name="$2"

    if ! _is_stack_running_for_secret_ops "$stack_name"; then
        return 0
    fi

    echo ""
    echo "[WARN] Stack '$stack_name' is currently running and may be using Docker secrets."
    echo "       Docker secrets cannot be removed while in use by running services."
    echo ""
    echo "       To recreate secret '$secret_name', the stack must be removed first."
    echo ""

    local remove_stack=""
    if [[ -r /dev/tty ]]; then
        read -r -p "Remove stack '$stack_name' now? (y/N): " remove_stack < /dev/tty
    else
        read -r -p "Remove stack '$stack_name' now? (y/N): " remove_stack
    fi

    if [[ ! "$remove_stack" =~ ^[Yy]$ ]]; then
        echo "[SKIP] Keeping stack running. Cannot recreate secret."
        return 1
    fi

    echo "Removing stack '$stack_name'..."
    docker stack rm "$stack_name" 2>/dev/null || true
    if _wait_for_stack_removal_for_secret_ops "$stack_name" 120; then
        sleep 2
        return 0
    fi

    echo "[WARN] Stack removal taking longer than expected. Please wait and retry."
    return 1
}

create_secret_interactive() {
    # create_secret_interactive
    # Interactively prompts for a secret value and creates a Docker secret.
    # Arguments:
    # - $1: secret name
    # - $2: description displayed to the user
    # Returns:
    # - 0 if created successfully
    # - 1 otherwise
    local secret_name="$1"
    local description="$2"
    
    echo ""
    echo "🔐 Creating secret: $secret_name"
    echo "   $description"
    echo ""
    read -sp "Enter value for $secret_name: " secret_value
    echo ""
    
    if [ -z "$secret_value" ]; then
        echo "❌ Secret value cannot be empty"
        return 1
    fi

    if check_secret_exists "$secret_name"; then
        local recreate=""
        if [[ -r /dev/tty ]]; then
            read -r -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate < /dev/tty
        else
            read -r -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate
        fi

        if [[ ! "$recreate" =~ ^[Yy]$ ]]; then
            echo "⏭️  Keeping existing secret: $secret_name"
            return 0
        fi

        local stack_name
        stack_name=$(_get_stack_name_for_secret_ops)
        if ! _ensure_stack_removed_for_secret_recreate "$secret_name" "$stack_name"; then
            return 1
        fi

        if ! docker secret rm "$secret_name" >/dev/null 2>&1; then
            echo "❌ Failed to remove secret: $secret_name (may still be in use)"
            return 1
        fi
    fi
    
    if printf '%s' "$secret_value" | docker secret create "$secret_name" - >/dev/null 2>&1; then
        echo "✅ Secret created: $secret_name"
        return 0
    fi

    echo "❌ Failed to create secret: $secret_name"
    return 1
}

create_secret_from_file() {
    # create_secret_from_file
    # Creates a Docker secret from an existing file.
    # Arguments:
    # - $1: secret name
    # - $2: file path
    # Returns:
    # - 0 if created successfully
    # - 1 otherwise
    local secret_name="$1"
    local file_path="$2"
    
    if [ ! -f "$file_path" ]; then
        echo "❌ File not found: $file_path"
        return 1
    fi

    if check_secret_exists "$secret_name"; then
        local recreate=""
        if [[ -r /dev/tty ]]; then
            read -r -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate < /dev/tty
        else
            read -r -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate
        fi

        if [[ ! "$recreate" =~ ^[Yy]$ ]]; then
            echo "⏭️  Keeping existing secret: $secret_name"
            return 0
        fi

        local stack_name
        stack_name=$(_get_stack_name_for_secret_ops)
        if ! _ensure_stack_removed_for_secret_recreate "$secret_name" "$stack_name"; then
            return 1
        fi

        if ! docker secret rm "$secret_name" >/dev/null 2>&1; then
            echo "❌ Failed to remove secret: $secret_name (may still be in use)"
            return 1
        fi
    fi
    
    docker secret create "$secret_name" "$file_path"
    
    if [ $? -eq 0 ]; then
        echo "✅ Secret created from file: $secret_name"
        return 0
    else
        echo "❌ Failed to create secret: $secret_name"
        return 1
    fi
}

create_secret_from_value() {
    local secret_name="$1"
    local secret_value="$2"

    if [ -z "$secret_name" ]; then
        return 1
    fi

    if [ -z "$secret_value" ]; then
        echo "❌ Secret value cannot be empty for $secret_name"
        return 1
    fi

    if check_secret_exists "$secret_name"; then
        local recreate=""
        if [[ -r /dev/tty ]]; then
            read -r -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate < /dev/tty
        else
            read -r -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate
        fi
        if [[ "$recreate" =~ ^[Yy]$ ]]; then
            local stack_name
            stack_name=$(_get_stack_name_for_secret_ops)
            if ! _ensure_stack_removed_for_secret_recreate "$secret_name" "$stack_name"; then
                return 1
            fi
            if ! docker secret rm "$secret_name" >/dev/null 2>&1; then
                echo "❌ Failed to remove secret: $secret_name (may still be in use)"
                return 1
            fi
        else
            echo "⏭️  Keeping existing secret: $secret_name"
            return 0
        fi
    fi

    echo -n "$secret_value" | docker secret create "$secret_name" - >/dev/null 2>&1
    return $?
}

create_secrets_from_env_file() {
    local secrets_file="${1:-secrets.env}"
    local template_file="${2:-setup/secrets.env.template}"

    local stack_name
    stack_name=$(_get_stack_name_for_secret_ops)

    if [ ! -f "$secrets_file" ]; then
        if [ -f "$template_file" ]; then
            cp "$template_file" "$secrets_file"
            echo "✅ Created $secrets_file from template: $template_file"
            read -p "Open $secrets_file in editor now? (Y/n): " open_file
            if [[ ! "$open_file" =~ ^[Nn]$ ]]; then
                if type wizard_choose_editor >/dev/null 2>&1 && type wizard_edit_file >/dev/null 2>&1; then
                    if [ -z "${WIZARD_EDITOR:-}" ]; then
                        wizard_choose_editor || true
                    fi
                    if [ -n "${WIZARD_EDITOR:-}" ]; then
                        wizard_edit_file "$secrets_file" "$WIZARD_EDITOR"
                    fi
                else
                    if command -v nano &> /dev/null; then
                        nano "$secrets_file"
                    elif command -v vim &> /dev/null; then
                        vim "$secrets_file"
                    else
                        echo "No editor found. Please edit $secrets_file manually."
                    fi
                fi
            fi
        else
            echo "❌ Secrets template not found: $template_file"
            return 1
        fi
    fi

    local key value
    while IFS='=' read -r key value || [ -n "$key" ]; do
        key="${key%$'\r'}"
        value="${value%$'\r'}"
        if [ -z "$key" ]; then
            continue
        fi
        case "$key" in
            \#*)
                continue
                ;;
        esac

        if [[ "$key" =~ ^\  ]]; then
            key="${key# }"
        fi

        if [ "$key" = "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON" ] && [ -n "$value" ] && [ -f "$value" ]; then
            create_secret_from_file "$key" "$value" || return 1
            continue
        fi

        if [ -n "$value" ]; then
            create_secret_from_value "$key" "$value" || return 1
        fi
    done < "$secrets_file"

    check_required_secrets
}

list_secrets() {
    # list_secrets
    # Lists all Docker secrets.
    echo "📋 Current secrets:"
    docker secret ls
}

check_required_secrets() {
    # check_required_secrets
    # Validates that all required secrets exist.
    # Returns:
    # - 0 if all required secrets exist
    # - 1 otherwise
    local all_exist=true
    local required_secrets=(
        "STATECHECKER_SERVER_AUTHENTICATION_TOKEN"
        "STATECHECKER_SERVER_DB_ROOT_USER_PW"
        "STATECHECKER_SERVER_DB_USER_PW"
    )
    
    echo "🔐 Checking required secrets..."
    
    for secret in "${required_secrets[@]}"; do
        if check_secret_exists "$secret"; then
            echo "   ✅ $secret"
        else
            echo "   ❌ $secret (missing)"
            all_exist=false
        fi
    done
    
    if [ "$all_exist" = true ]; then
        return 0
    else
        return 1
    fi
}

check_optional_secrets() {
    # check_optional_secrets
    # Prints the status of optional (non-required) secrets.
    local optional_secrets=(
        "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN"
        "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD"
        "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON"
    )
    
    echo ""
    echo "🔐 Checking optional secrets..."
    
    for secret in "${optional_secrets[@]}"; do
        if check_secret_exists "$secret"; then
            echo "   ✅ $secret"
        else
            echo "   ⚠️  $secret (not configured)"
        fi
    done
}
