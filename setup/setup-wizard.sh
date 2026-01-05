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
source "$SCRIPT_DIR/modules/data-dirs.sh"
source "$SCRIPT_DIR/modules/wizard.sh"

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
    update_env_values "$PROJECT_ROOT/.env" "DATA_ROOT" "$PROJECT_ROOT"
    echo "✅ Created .env from template"
    return 0
}

_validate_domain() {
    # _validate_domain
    # Validates domain format (must have at least two dots).
    local domain="$1"
    local pattern='^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+\.[A-Za-z]{2,}$'
    [[ "$domain" =~ $pattern ]]
}

_prompt_domain_with_validation() {
    # _prompt_domain_with_validation
    # Prompts for a domain with validation and guidance.
    local prompt_text="$1"
    local default_value="$2"
    local domain_name="$3"
    local result=""
    local wiki_url="https://wiki.fe-wi.com/en/deployment/create-subdomain"
    
    while true; do
        read_prompt "$prompt_text [$default_value] (if you need to create a new subdomain, see $wiki_url): " result
        result="${result:-$default_value}"
        
        if [ -z "$result" ]; then
            echo "[WARN] Domain is required for Traefik" >&2
            continue
        fi
        
        if _validate_domain "$result"; then
            echo "$result"
            return 0
        else
            echo "[WARN] Please enter a valid domain like $domain_name (must contain at least two dots)." >&2
            echo "       If you need to create a new subdomain, see $wiki_url" >&2
        fi
    done
}

_prompt_proxy_config() {
    # _prompt_proxy_config
    # Prompts for proxy-related configuration based on selected proxy type.
    local env_file="$1"
    local proxy_type="$2"

    if [ "$proxy_type" = "none" ]; then
        local current_web_port current_pma_port
        current_web_port=$(grep '^WEB_PORT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_pma_port=$(grep '^PHPMYADMIN_PORT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        
        read_prompt "WEB_PORT (localhost) [${current_web_port:-8080}]: " web_port
        update_env_values "$env_file" "WEB_PORT" "${web_port:-${current_web_port:-8080}}"
        
        read_prompt "PHPMYADMIN_PORT (localhost) [${current_pma_port:-8081}]: " pma_port
        update_env_values "$env_file" "PHPMYADMIN_PORT" "${pma_port:-${current_pma_port:-8081}}"
    else
        local current_traefik current_api_url current_web_url current_pma_url
        current_traefik=$(grep '^TRAEFIK_NETWORK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_api_url=$(grep '^API_URL=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_web_url=$(grep '^WEB_URL=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_pma_url=$(grep '^PHPMYADMIN_URL=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

        local traefik_network
        traefik_network=$(prompt_traefik_network "${current_traefik:-traefik}")
        update_env_values "$env_file" "TRAEFIK_NETWORK_NAME" "$traefik_network"

        echo ""
        echo "[CONFIG] Domain Configuration for Traefik"
        echo "------------------------------------------"
        echo "Configure the domains for each service. These must be valid FQDNs"
        echo "pointing to your server (e.g., api.statechecker.example.com)."
        echo ""

        local api_url
        api_url=$(_prompt_domain_with_validation "API_URL (Traefik Host)" "${current_api_url:-api.statechecker.domain.de}" "api.statechecker.example.com")
        update_env_values "$env_file" "API_URL" "$api_url"

        local web_url
        web_url=$(_prompt_domain_with_validation "WEB_URL (Traefik Host)" "${current_web_url:-web.statechecker.domain.de}" "web.statechecker.example.com")
        update_env_values "$env_file" "WEB_URL" "$web_url"

        local pma_url
        pma_url=$(_prompt_domain_with_validation "PHPMYADMIN_URL (Traefik Host)" "${current_pma_url:-phpmyadmin.statechecker.domain.de}" "phpmyadmin.statechecker.example.com")
        update_env_values "$env_file" "PHPMYADMIN_URL" "$pma_url"
    fi
}

_prompt_image_config() {
    # _prompt_image_config
    # Prompts for Docker image names and versions.
    local env_file="$1"
    local current_image current_tag current_web_image current_web_tag
    current_image=$(grep '^IMAGE_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_tag=$(grep '^IMAGE_VERSION=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_web_image=$(grep '^WEB_IMAGE_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_web_tag=$(grep '^WEB_IMAGE_VERSION=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    read_prompt "API/CHECK image name [${current_image:-sokrates1989/statechecker}]: " image_name
    update_env_values "$env_file" "IMAGE_NAME" "${image_name:-${current_image:-sokrates1989/statechecker}}"

    read_prompt "API/CHECK image tag [${current_tag:-latest}]: " image_tag
    update_env_values "$env_file" "IMAGE_VERSION" "${image_tag:-${current_tag:-latest}}"

    read_prompt "WEB image name [${current_web_image:-sokrates1989/statechecker-web}]: " web_image_name
    update_env_values "$env_file" "WEB_IMAGE_NAME" "${web_image_name:-${current_web_image:-sokrates1989/statechecker-web}}"

    read_prompt "WEB image tag [${current_web_tag:-latest}]: " web_image_tag
    update_env_values "$env_file" "WEB_IMAGE_VERSION" "${web_image_tag:-${current_web_tag:-latest}}"
}

prompt_update_env_values() {
    # prompt_update_env_values
    # Prompts the user for key env values and persists them into .env.
    local env_file="$1"
    local current_stack_name current_data_root current_proxy_type

    current_stack_name=$(grep '^STACK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_data_root=$(grep '^DATA_ROOT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_proxy_type=$(grep '^PROXY_TYPE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    echo -e "\n==========================\n  Basic configuration\n==========================\n"

    local default_stack_name="statechecker"
    read_prompt "Stack name [${current_stack_name:-$default_stack_name}]: " stack_name
    update_env_values "$env_file" "STACK_NAME" "${stack_name:-${current_stack_name:-$default_stack_name}}"

    local default_data_root="${PROJECT_ROOT:-$(pwd)}"
    read_prompt "Data root [$default_data_root]: " data_root
    update_env_values "$env_file" "DATA_ROOT" "${data_root:-$default_data_root}"

    read_prompt "Proxy type (traefik/none) [${current_proxy_type:-traefik}]: " proxy_type
    proxy_type=${proxy_type:-${current_proxy_type:-traefik}}
    [[ "$proxy_type" != "traefik" && "$proxy_type" != "none" ]] && proxy_type="traefik"
    update_env_values "$env_file" "PROXY_TYPE" "$proxy_type"

    _prompt_proxy_config "$env_file" "$proxy_type"
    _prompt_image_config "$env_file"
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

    echo "How would you like to configure deployment settings?"
    echo "1) Edit .env file (built from templates) and let the wizard read values from it"
    echo "2) Answer questions interactively now (recommended)"
    echo ""
    read_prompt "Your choice (1-2) [2]: " config_mode
    config_mode="${config_mode:-2}"

    if [ "$config_mode" = "1" ]; then
        if [ -z "${WIZARD_EDITOR:-}" ]; then
            wizard_choose_editor || exit 1
        fi
        wizard_edit_file "$PROJECT_ROOT/.env" "$WIZARD_EDITOR"

        set -a
        source "$PROJECT_ROOT/.env"
        set +a

        STACK_NAME="${STACK_NAME:-statechecker}"
        DATA_ROOT="${DATA_ROOT:-$PROJECT_ROOT}"
        PROXY_TYPE="${PROXY_TYPE:-traefik}"

        update_env_values "$PROJECT_ROOT/.env" "STACK_NAME" "$STACK_NAME"
        update_env_values "$PROJECT_ROOT/.env" "DATA_ROOT" "$DATA_ROOT"
        update_env_values "$PROJECT_ROOT/.env" "PROXY_TYPE" "$PROXY_TYPE"

        if [ "$PROXY_TYPE" = "traefik" ]; then
            if [ -z "${TRAEFIK_NETWORK_NAME:-}" ]; then
                traefik_network=$(prompt_traefik_network "traefik")
                update_env_values "$PROJECT_ROOT/.env" "TRAEFIK_NETWORK_NAME" "$traefik_network"
            fi

            if [ -z "${API_URL:-}" ]; then
                api_url=$(_prompt_domain_with_validation "API_URL (Traefik Host)" "api.statechecker.domain.de" "api.statechecker.example.com")
                update_env_values "$PROJECT_ROOT/.env" "API_URL" "$api_url"
            fi
            if [ -z "${WEB_URL:-}" ]; then
                web_url=$(_prompt_domain_with_validation "WEB_URL (Traefik Host)" "web.statechecker.domain.de" "web.statechecker.example.com")
                update_env_values "$PROJECT_ROOT/.env" "WEB_URL" "$web_url"
            fi
            if [ -z "${PHPMYADMIN_URL:-}" ]; then
                pma_url=$(_prompt_domain_with_validation "PHPMYADMIN_URL (Traefik Host)" "phpmyadmin.statechecker.domain.de" "phpmyadmin.statechecker.example.com")
                update_env_values "$PROJECT_ROOT/.env" "PHPMYADMIN_URL" "$pma_url"
            fi
        fi

        IMAGE_NAME="${IMAGE_NAME:-sokrates1989/statechecker}"
        IMAGE_VERSION="${IMAGE_VERSION:-latest}"
        WEB_IMAGE_NAME="${WEB_IMAGE_NAME:-sokrates1989/statechecker-web}"
        WEB_IMAGE_VERSION="${WEB_IMAGE_VERSION:-latest}"
        update_env_values "$PROJECT_ROOT/.env" "IMAGE_NAME" "$IMAGE_NAME"
        update_env_values "$PROJECT_ROOT/.env" "IMAGE_VERSION" "$IMAGE_VERSION"
        update_env_values "$PROJECT_ROOT/.env" "WEB_IMAGE_NAME" "$WEB_IMAGE_NAME"
        update_env_values "$PROJECT_ROOT/.env" "WEB_IMAGE_VERSION" "$WEB_IMAGE_VERSION"
    else
        prompt_update_env_values "$PROJECT_ROOT/.env"
    fi

    local data_root
    data_root=$(grep '^DATA_ROOT=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    prepare_data_root "$data_root" "$PROJECT_ROOT" || exit 1

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
