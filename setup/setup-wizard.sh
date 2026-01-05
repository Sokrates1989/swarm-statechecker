#!/bin/bash
# ------------------------------------------------------------------------------
# setup-wizard.sh - Interactive setup wizard for Swarm Statechecker
# ------------------------------------------------------------------------------

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# Source helper modules (re-use existing helpers)
source "$SCRIPT_DIR/modules/docker_helpers.sh"
source "$SCRIPT_DIR/modules/menu_handlers.sh"

is_setup_complete() {
    # is_setup_complete
    # Determines whether setup has already been completed.
    #
    # Returns:
    # - 0 if setup is complete
    # - 1 otherwise
    if [ -f "$PROJECT_ROOT/.setup-complete" ]; then
        return 0
    fi

    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi

    return 1
}

ensure_env_file() {
    # ensure_env_file
    # Ensures a .env exists in the project root.
    #
    # Returns:
    # - 0 on success
    # - 1 on failure
    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi

    if [ ! -f "$SCRIPT_DIR/.env.template" ]; then
        echo "❌ Missing env template: $SCRIPT_DIR/.env.template"
        return 1
    fi

    cp "$SCRIPT_DIR/.env.template" "$PROJECT_ROOT/.env"
    echo "✅ Created .env from template"
    return 0
}

prompt_update_env_values() {
    # prompt_update_env_values
    # Prompts the user for key env values and persists them into .env.
    #
    # Arguments:
    # - $1: path to .env file
    local env_file="$1"

    local current_stack_name
    current_stack_name=$(grep '^STACK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_stack_name=${current_stack_name:-statechecker-server}

    local current_data_root
    current_data_root=$(grep '^DATA_ROOT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_data_root=${current_data_root:-/gluster_storage/swarm/monitoring/statechecker-server}

    echo ""
    echo "=========================="
    echo "  Basic configuration"
    echo "=========================="
    echo ""

    read_prompt "Stack name [$current_stack_name]: " stack_name
    stack_name=${stack_name:-$current_stack_name}
    update_env_values "$env_file" "STACK_NAME" "$stack_name"

    read_prompt "Data root [$current_data_root]: " data_root
    data_root=${data_root:-$current_data_root}
    update_env_values "$env_file" "DATA_ROOT" "$data_root"

    local current_proxy_type
    current_proxy_type=$(grep '^PROXY_TYPE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_proxy_type=${current_proxy_type:-traefik}
    read_prompt "Proxy type (traefik/none) [$current_proxy_type]: " proxy_type
    proxy_type=${proxy_type:-$current_proxy_type}
    if [ "$proxy_type" != "traefik" ] && [ "$proxy_type" != "none" ]; then
        proxy_type="traefik"
    fi
    update_env_values "$env_file" "PROXY_TYPE" "$proxy_type"

    if [ "$proxy_type" = "none" ]; then
        local current_web_port
        current_web_port=$(grep '^WEB_PORT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_web_port=${current_web_port:-8080}
        read_prompt "WEB_PORT (localhost) [$current_web_port]: " web_port
        web_port=${web_port:-$current_web_port}
        update_env_values "$env_file" "WEB_PORT" "$web_port"

        local current_pma_port
        current_pma_port=$(grep '^PHPMYADMIN_PORT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_pma_port=${current_pma_port:-8081}
        read_prompt "PHPMYADMIN_PORT (localhost) [$current_pma_port]: " pma_port
        pma_port=${pma_port:-$current_pma_port}
        update_env_values "$env_file" "PHPMYADMIN_PORT" "$pma_port"
    fi

    if [ "$proxy_type" = "traefik" ]; then
        local current_traefik
        current_traefik=$(grep '^TRAEFIK_NETWORK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        if [ -z "$current_traefik" ]; then
            current_traefik="traefik"
        fi

        read_prompt "Traefik network name [$current_traefik]: " traefik_network
        traefik_network=${traefik_network:-$current_traefik}
        update_env_values "$env_file" "TRAEFIK_NETWORK_NAME" "$traefik_network"

        local current_api_url
        current_api_url=$(grep '^API_URL=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_api_url=${current_api_url:-api.statechecker.domain.de}
        read_prompt "API_URL (Traefik Host) [$current_api_url]: " api_url
        api_url=${api_url:-$current_api_url}
        update_env_values "$env_file" "API_URL" "$api_url"

        local current_web_url
        current_web_url=$(grep '^WEB_URL=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_web_url=${current_web_url:-web.statechecker.domain.de}
        read_prompt "WEB_URL (Traefik Host) [$current_web_url]: " web_url
        web_url=${web_url:-$current_web_url}
        update_env_values "$env_file" "WEB_URL" "$web_url"

        local current_pma_url
        current_pma_url=$(grep '^PHPMYADMIN_URL=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_pma_url=${current_pma_url:-phpmyadmin.statechecker.domain.de}
        read_prompt "PHPMYADMIN_URL (Traefik Host) [$current_pma_url]: " pma_url
        pma_url=${pma_url:-$current_pma_url}
        update_env_values "$env_file" "PHPMYADMIN_URL" "$pma_url"
    fi

    local current_image
    current_image=$(grep '^IMAGE_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_image=${current_image:-sokrates1989/statechecker}
    read_prompt "API/CHECK image name [$current_image]: " image_name
    image_name=${image_name:-$current_image}
    update_env_values "$env_file" "IMAGE_NAME" "$image_name"

    local current_tag
    current_tag=$(grep '^IMAGE_VERSION=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_tag=${current_tag:-latest}
    read_prompt "API/CHECK image tag [$current_tag]: " image_tag
    image_tag=${image_tag:-$current_tag}
    update_env_values "$env_file" "IMAGE_VERSION" "$image_tag"

    local current_web_image
    current_web_image=$(grep '^WEB_IMAGE_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_web_image=${current_web_image:-sokrates1989/statechecker-web}
    read_prompt "WEB image name [$current_web_image]: " web_image_name
    web_image_name=${web_image_name:-$current_web_image}
    update_env_values "$env_file" "WEB_IMAGE_NAME" "$web_image_name"

    local current_web_tag
    current_web_tag=$(grep '^WEB_IMAGE_VERSION=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_web_tag=${current_web_tag:-latest}
    read_prompt "WEB image tag [$current_web_tag]: " web_image_tag
    web_image_tag=${web_image_tag:-$current_web_tag}
    update_env_values "$env_file" "WEB_IMAGE_VERSION" "$web_image_tag"
}

prepare_data_root() {
    # prepare_data_root
    # Creates all required directories under DATA_ROOT and copies required install
    # files (DB schema and migrations) into place.
    #
    # Arguments:
    # - $1: DATA_ROOT directory
    local data_root="$1"

    if [ -z "$data_root" ]; then
        echo "❌ DATA_ROOT cannot be empty"
        return 1
    fi

    echo ""
    echo "[DATA] Preparing DATA_ROOT: $data_root"

    mkdir -p "$data_root/logs/api" "$data_root/logs/check" "$data_root/db_data" "$data_root/install/database/migrations"

    if [ ! -f "$PROJECT_ROOT/install/database/state_checker.sql" ]; then
        echo "❌ Missing schema file: $PROJECT_ROOT/install/database/state_checker.sql"
        return 1
    fi

    cp "$PROJECT_ROOT/install/database/state_checker.sql" "$data_root/install/database/state_checker.sql"

    if [ -d "$PROJECT_ROOT/install/database/migrations" ]; then
        cp -R "$PROJECT_ROOT/install/database/migrations/"* "$data_root/install/database/migrations/" 2>/dev/null || true
        if [ -f "$data_root/install/database/migrations/run_migrations.sh" ]; then
            chmod +x "$data_root/install/database/migrations/run_migrations.sh" 2>/dev/null || true
        fi
    fi

    echo "✅ DATA_ROOT prepared"
    return 0
}

mark_setup_complete() {
    # mark_setup_complete
    # Writes the setup completion marker file.
    : > "$PROJECT_ROOT/.setup-complete"
}

main() {
    # main
    # Entry point for the setup wizard.

    echo "=========================================="
    echo "  Swarm Statechecker - Setup Wizard"
    echo "=========================================="
    echo ""

    if ! check_docker_swarm; then
        exit 1
    fi

    if is_setup_complete; then
        echo "[WARN] Setup appears to be already complete."
        read_prompt "Run setup again? This will overwrite .env and re-copy install files (y/N): " rerun
        if [[ ! "$rerun" =~ ^[Yy]$ ]]; then
            echo "Setup cancelled."
            exit 0
        fi
    fi

    ensure_env_file || exit 1

    prompt_update_env_values "$PROJECT_ROOT/.env"

    local data_root
    data_root=$(grep '^DATA_ROOT=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    prepare_data_root "$data_root" || exit 1

    echo ""
    echo "=========================="
    echo "  Secrets"
    echo "=========================="
    echo ""

    if ! check_required_secrets; then
        echo ""
        echo "[WARN] Some required secrets are missing"
        echo "How do you want to create secrets?"
        echo "1) Create from secrets.env file"
        echo "2) Create interactively"
        echo ""
        read_prompt "Your choice (1-2) [2]: " secrets_choice
        secrets_choice="${secrets_choice:-2}"

        if [ "$secrets_choice" = "1" ]; then
            create_secrets_from_env_file "secrets.env" "$SCRIPT_DIR/secrets.env.template" || true
        else
            create_required_secrets_menu
        fi

        echo ""
        check_required_secrets || true
    fi

    read_prompt "Create optional secrets now (Telegram/Email/Google Drive)? (y/N): " create_optional
    if [[ "$create_optional" =~ ^[Yy]$ ]]; then
        create_optional_secrets_menu
    fi

    mark_setup_complete

    echo ""
    echo "✅ Setup complete. You can now run ./quick-start.sh to manage the stack."
}

main "$@"
