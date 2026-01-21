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
source "$SCRIPT_DIR/modules/health-check.sh"
source "$SCRIPT_DIR/modules/data-dirs.sh"
source "$SCRIPT_DIR/modules/wizard.sh"
source "$SCRIPT_DIR/modules/config-builder.sh"
source "$SCRIPT_DIR/modules/backup_integration.sh"

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
    return 1
}

_validate_website_domain_or_path() {
    # _validate_website_domain_or_path
    # Validates a domain or domain+path+port like example.com, example.com/path, example.com:8443/path.
    local value="$1"
    local pattern='^[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:[0-9]{1,5})?([/?#].*)?$'
    [[ "$value" =~ $pattern ]]
}

_validate_http_url() {
    # _validate_http_url
    # Validates a URL with http/https scheme.
    local value="$1"
    local pattern='^https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:[0-9]{1,5})?([/?#].*)?$'
    [[ "$value" =~ $pattern ]]
}

_expand_website_to_monitor_urls() {
    # _expand_website_to_monitor_urls
    # Accepts either a full URL (http/https) or a domain.
    # If a domain is provided, returns both https:// and http:// URLs (one per line).
    local raw="$1"
    raw="${raw//$'\r'/}"
    raw="${raw#${raw%%[![:space:]]*}}"
    raw="${raw%${raw##*[![:space:]]}}"

    if [[ "$raw" =~ ^https?:// ]]; then
        if _validate_http_url "$raw"; then
            printf '%s\n' "$raw"
            return 0
        fi
        return 1
    fi

    if _validate_website_domain_or_path "$raw"; then
        printf '%s\n' "https://$raw"
        printf '%s\n' "http://$raw"
        return 0
    fi

    return 1
}

ensure_env_file() {
    # ensure_env_file
    # Ensures a .env exists in the project root using modular templates.
    #
    # Arguments:
    # - $1: proxy_type (traefik or none)
    #
    # Returns:
    # - 0 on success
    # - 1 on failure
    local proxy_type="${1:-traefik}"
    
    if [ -f "$PROJECT_ROOT/.env" ]; then
        return 0
    fi

    if [ ! -f "$SCRIPT_DIR/env-templates/.env.base.template" ]; then
        echo "❌ Missing env template: $SCRIPT_DIR/env-templates/.env.base.template"
        return 1
    fi

    build_env_file "$proxy_type" "$PROJECT_ROOT"
    update_env_values "$PROJECT_ROOT/.env" "DATA_ROOT" "$PROJECT_ROOT"
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
            # Output only the result to stdout for capture
            echo "$result"
            return 0
        else
            echo "[WARN] Please enter a valid domain like $domain_name (must contain at least two dots)." >&2
            echo "       If you need to create a new subdomain, see $wiki_url" >&2
        fi
    done
}

_prompt_ssl_mode() {
    # _prompt_ssl_mode
    # Prompts for SSL termination mode when using Traefik.
    #
    # Returns:
    # - "direct" if Traefik handles SSL directly (Let's Encrypt)
    # - "proxy" if Traefik is behind another TLS terminator
    local current_ssl_mode="$1"
    
    echo "" >&2
    echo "[CONFIG] SSL Termination Mode" >&2
    echo "------------------------------" >&2
    echo "How is SSL/TLS handled in your setup?" >&2
    echo "1) direct - Traefik handles SSL directly (uses Let's Encrypt)" >&2
    echo "2) proxy  - Traefik is behind another TLS terminator (e.g., Nginx Proxy Manager)" >&2
    echo "" >&2
    
    local default_choice="1"
    if [ "$current_ssl_mode" = "proxy" ]; then
        default_choice="2"
    fi
    
    read_prompt "Your choice (1-2) [$default_choice]: " ssl_choice
    ssl_choice="${ssl_choice:-$default_choice}"
    
    if [ "$ssl_choice" = "2" ]; then
        echo "proxy"
    else
        echo "direct"
    fi
}

_prompt_proxy_config() {
    # _prompt_proxy_config
    # Prompts for proxy-related configuration based on selected proxy type.
    #
    # Arguments:
    # - $1: env_file path
    # - $2: proxy_type (traefik or none)
    #
    # Returns (via global):
    # - Sets SSL_MODE variable for later use in stack generation
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
        
        SSL_MODE=""
    else
        local current_traefik current_api_domain current_web_domain current_pma_domain current_ssl_mode
        current_traefik=$(grep '^TRAEFIK_NETWORK=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_api_domain=$(grep '^API_DOMAIN=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_web_domain=$(grep '^WEB_DOMAIN=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_pma_domain=$(grep '^PHPMYADMIN_DOMAIN=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        current_ssl_mode=$(grep '^SSL_MODE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

        local traefik_network
        traefik_network=$(prompt_traefik_network "${current_traefik:-traefik}")
        update_env_values "$env_file" "TRAEFIK_NETWORK" "$traefik_network"

        SSL_MODE=$(_prompt_ssl_mode "${current_ssl_mode:-direct}")
        update_env_values "$env_file" "SSL_MODE" "$SSL_MODE"

        echo "" >&2
        echo "[CONFIG] Domain Configuration for Traefik" >&2
        echo "------------------------------------------" >&2
        echo "Configure the domains for each service. These must be valid FQDNs" >&2
        echo "pointing to your server (e.g., api.statechecker.example.com)." >&2
        echo "" >&2

        local api_domain
        api_domain=$(_prompt_domain_with_validation "API_DOMAIN (Traefik Host)" "${current_api_domain:-api.statechecker.domain.de}" "api.statechecker.example.com")
        update_env_values "$env_file" "API_DOMAIN" "$api_domain"

        local web_domain
        web_domain=$(_prompt_domain_with_validation "WEB_DOMAIN (Traefik Host)" "${current_web_domain:-statechecker.domain.de}" "statechecker.example.com")
        update_env_values "$env_file" "WEB_DOMAIN" "$web_domain"

        local pma_domain
        pma_domain=$(_prompt_domain_with_validation "PHPMYADMIN_DOMAIN (Traefik Host)" "${current_pma_domain:-pma.statechecker.domain.de}" "pma.statechecker.example.com")
        update_env_values "$env_file" "PHPMYADMIN_DOMAIN" "$pma_domain"

        local current_pma_replicas
        current_pma_replicas=$(grep '^PHPMYADMIN_REPLICAS=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        local pma_default="N"
        if [ "${current_pma_replicas:-0}" != "0" ]; then
            pma_default="Y"
        fi
        local enable_pma
        read_prompt "Enable phpMyAdmin? (y/N) [$pma_default]: " enable_pma
        enable_pma="${enable_pma:-$pma_default}"
        if [[ "$enable_pma" =~ ^[Yy]$ ]]; then
            update_env_values "$env_file" "PHPMYADMIN_REPLICAS" "1"
        else
            update_env_values "$env_file" "PHPMYADMIN_REPLICAS" "0"
        fi
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

_prompt_timezone_config() {
    # _prompt_timezone_config
    # Prompts for TIMEZONE and persists it into .env.
    local env_file="$1"
    local current_timezone
    current_timezone=$(grep '^TIMEZONE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    read_prompt "Timezone [${current_timezone:-Europe/Berlin}]: " timezone
    update_env_values "$env_file" "TIMEZONE" "${timezone:-${current_timezone:-Europe/Berlin}}"
}

_prompt_telegram_config() {
    # _prompt_telegram_config
    # Prompts for Telegram-related configuration and persists it into .env.
    local env_file="$1"
    local current_enabled current_error_ids current_info_ids current_status_minutes

    current_enabled=$(grep '^TELEGRAM_ENABLED=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_error_ids=$(grep '^TELEGRAM_RECIPIENTS_ERROR_CHAT_IDS=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_info_ids=$(grep '^TELEGRAM_RECIPIENTS_INFO_CHAT_IDS=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_status_minutes=$(grep '^TELEGRAM_STATUS_MESSAGES_EVERY_X_MINUTES=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    read_prompt "Enable Telegram notifications? (y/N): " enable_telegram
    if [[ "$enable_telegram" =~ ^[Yy]$ ]]; then
        update_env_values "$env_file" "TELEGRAM_ENABLED" "true"

        read_prompt "Telegram error chat IDs (comma-separated) [${current_error_ids:--123456789}]: " telegram_error
        update_env_values "$env_file" "TELEGRAM_RECIPIENTS_ERROR_CHAT_IDS" "${telegram_error:-${current_error_ids:--123456789}}"

        read_prompt "Telegram info chat IDs (comma-separated) [${current_info_ids:--123456789}]: " telegram_info
        update_env_values "$env_file" "TELEGRAM_RECIPIENTS_INFO_CHAT_IDS" "${telegram_info:-${current_info_ids:--123456789}}"

        read_prompt "Telegram status messages every X minutes [${current_status_minutes:-60}]: " telegram_status
        update_env_values "$env_file" "TELEGRAM_STATUS_MESSAGES_EVERY_X_MINUTES" "${telegram_status:-${current_status_minutes:-60}}"
    else
        update_env_values "$env_file" "TELEGRAM_ENABLED" "false"
    fi
}

_prompt_email_config() {
    # _prompt_email_config
    # Prompts for Email-related configuration and persists it into .env.
    local env_file="$1"
    local current_enabled current_user current_host current_port current_rcpt_err current_rcpt_info

    current_enabled=$(grep '^EMAIL_ENABLED=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_user=$(grep '^EMAIL_SENDER_USER=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_host=$(grep '^EMAIL_SENDER_HOST=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_port=$(grep '^EMAIL_SENDER_PORT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_rcpt_err=$(grep '^EMAIL_RECIPIENTS_ERROR=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_rcpt_info=$(grep '^EMAIL_RECIPIENTS_INFORMATION=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    read_prompt "Enable Email notifications? (y/N): " enable_email
    if [[ "$enable_email" =~ ^[Yy]$ ]]; then
        update_env_values "$env_file" "EMAIL_ENABLED" "true"

        read_prompt "Email sender user [${current_user:-some.mail@domain.com}]: " email_user
        update_env_values "$env_file" "EMAIL_SENDER_USER" "${email_user:-${current_user:-some.mail@domain.com}}"

        read_prompt "Email SMTP host [${current_host:-smtp.example.com}]: " email_host
        update_env_values "$env_file" "EMAIL_SENDER_HOST" "${email_host:-${current_host:-smtp.example.com}}"

        read_prompt "Email SMTP port [${current_port:-587}]: " email_port
        update_env_values "$env_file" "EMAIL_SENDER_PORT" "${email_port:-${current_port:-587}}"

        read_prompt "Email recipients (error) [${current_rcpt_err:-mail1@domain.com}]: " email_rcpt_err
        update_env_values "$env_file" "EMAIL_RECIPIENTS_ERROR" "${email_rcpt_err:-${current_rcpt_err:-mail1@domain.com}}"

        read_prompt "Email recipients (information) [${current_rcpt_info:-mail1@domain.com}]: " email_rcpt_info
        update_env_values "$env_file" "EMAIL_RECIPIENTS_INFORMATION" "${email_rcpt_info:-${current_rcpt_info:-mail1@domain.com}}"
    else
        update_env_values "$env_file" "EMAIL_ENABLED" "false"
    fi
}

_prompt_websites_to_check() {
    # _prompt_websites_to_check
    # Prompts for a list of websites to check.
    #
    # Returns:
    # - A JSON array string (e.g. ["https://a","https://b"]) via stdout
    local websites=()
    local -A website_seen
    local input_url=""

    echo "" >&2
    echo "[CONFIG] Websites to Monitor" >&2
    echo "---------------------------" >&2
    echo "Enter websites you want to monitor (one per prompt)." >&2
    echo "You can enter either a full URL (https://example.com/path) or just a domain (example.com)." >&2
    echo "If you enter only a domain, both https:// and http:// will be checked." >&2
    echo "" >&2

    while true; do
        read_prompt "Website to monitor (URL or domain; empty to finish): " input_url
        input_url="${input_url%$'\r'}"
        if [ -z "$input_url" ]; then
            if [ ${#websites[@]} -eq 0 ]; then
                echo "[WARN] Please enter at least one website to monitor (e.g., https://example.com or example.com)" >&2
                continue
            fi
            break
        fi

        local expanded
        if ! expanded=$(_expand_website_to_monitor_urls "$input_url"); then
            echo "[WARN] Please enter a valid URL (http:// or https://) or a valid domain like example.com" >&2
            continue
        fi

        local url
        while IFS= read -r url; do
            url="${url//$'\r'/}"
            if [ -n "$url" ] && [ -z "${website_seen[$url]+x}" ]; then
                websites+=("$url")
                website_seen[$url]=1
                echo "✅ Added: $url" >&2
            fi
        done <<< "$expanded"
    done

    local json="["
    local first=true
    local url
    for url in "${websites[@]}"; do
        local escaped
        escaped="$url"
        escaped="${escaped//\\/\\\\}"
        escaped="${escaped//\"/\\\"}"
        if [ "$first" = true ]; then
            first=false
        else
            json+="," 
        fi
        json+="\"${escaped}\""
    done
    json+="]"

    if [[ ! "$json" =~ ^\[.*\]$ ]]; then
        echo "[ERROR] Internal error: websites list is not a JSON array." >&2
        return 1
    fi

    # Return only the JSON to stdout
    printf '%s\n' "$json"
}

_update_statechecker_server_config() {
    # _update_statechecker_server_config
    # Regenerates STATECHECKER_SERVER_CONFIG based on env values and websites list.
    local env_file="$1"
    local websites_json_array="$2"

    local tz check_web_every check_gd_every status_offset
    local telegram_err telegram_info telegram_status

    tz=$(grep '^TIMEZONE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')
    check_web_every=$(grep '^CHECK_WEBSITES_EVERY_X_MINUTES=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')
    check_gd_every=$(grep '^CHECK_GOOGLEDRIVE_EVERY_X_MINUTES=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')
    status_offset=$(grep '^STATUS_MESSAGES_TIME_OFFSET_PERCENTAGE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')

    telegram_err=$(grep '^TELEGRAM_RECIPIENTS_ERROR_CHAT_IDS=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')
    telegram_info=$(grep '^TELEGRAM_RECIPIENTS_INFO_CHAT_IDS=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')
    telegram_status=$(grep '^TELEGRAM_STATUS_MESSAGES_EVERY_X_MINUTES=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"\r')

    check_web_every="${check_web_every:-30}"
    check_gd_every="${check_gd_every:-60}"
    status_offset="${status_offset:-2.5}"
    telegram_status="${telegram_status:-60}"

    websites_json_array="${websites_json_array//$'\r'/}"

    local config_json
    config_json="{\"toolsUsingApi_tolerancePeriod_inSeconds\":\"100\",\"telegram\":{\"botToken\":\"USE_SECRET_INSTEAD\",\"errorChatID\":\"${telegram_err}\",\"infoChatID\":\"${telegram_info}\",\"adminStatusMessage_everyXMinutes\":\"${telegram_status}\",\"adminStatusMessage_operationTime_offsetPercentage\":\"${status_offset}\"},\"websites\":{\"checkWebSitesEveryXMinutes\":${check_web_every},\"websitesToCheck\":${websites_json_array}},\"googleDrive\":{\"checkFilesEveryXMinutes\":${check_gd_every},\"foldersToCheck\":[]}}"

    config_json="${config_json//$'\r'/}"

    update_env_values "$env_file" "STATECHECKER_SERVER_CONFIG" "$config_json"
}

prompt_update_env_values() {
    # prompt_update_env_values
    # Prompts the user for key env values and persists them into .env.
    local env_file="$1"
    local current_stack_name current_data_root current_proxy_type

    current_stack_name=$(grep '^STACK_NAME=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_data_root=$(grep '^DATA_ROOT=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    current_proxy_type=$(grep '^PROXY_TYPE=' "$env_file" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    echo -e "\n==========================\n  Basic configuration\n==========================\n" >&2

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

    echo "" >&2
    echo "==========================" >&2
    echo "  Notifications & Timezone" >&2
    echo "==========================" >&2
    echo "" >&2

    _prompt_timezone_config "$env_file"
    _prompt_telegram_config "$env_file"
    _prompt_email_config "$env_file"

    local websites_json
    if ! websites_json=$(_prompt_websites_to_check); then
        echo "❌ [ERROR] Failed to collect websites list. Aborting wizard." >&2
        exit 1
    fi
    _update_statechecker_server_config "$env_file" "$websites_json"
}

mark_setup_complete() {
    # mark_setup_complete
    # Writes the setup completion marker file.
    : > "$PROJECT_ROOT/.setup-complete"
}

main() {
    # main
    # Entry point for the setup wizard.

    echo "==========================================" >&2
    echo "  Swarm Statechecker - Setup Wizard" >&2
    echo "==========================================" >&2
    echo "" >&2

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

    echo "How would you like to configure deployment settings?"  >&2
    echo "1) Edit .env file (built from templates) and let the wizard read values from it" >&2
    echo "2) Answer questions interactively now (recommended)" >&2
    echo "" >&2
    read_prompt "Your choice (1-2) [2]: " config_mode
    config_mode="${config_mode:-2}"

    if [ "$config_mode" = "1" ]; then
        if [ -z "${WIZARD_EDITOR:-}" ]; then
            wizard_choose_editor || exit 1
        fi
        wizard_edit_file "$PROJECT_ROOT/.env" "$WIZARD_EDITOR"

        load_env || true

        STACK_NAME="${STACK_NAME:-statechecker}"
        DATA_ROOT="${DATA_ROOT:-$PROJECT_ROOT}"
        PROXY_TYPE="${PROXY_TYPE:-traefik}"
        SSL_MODE="${SSL_MODE:-direct}"

        update_env_values "$PROJECT_ROOT/.env" "STACK_NAME" "$STACK_NAME"
        update_env_values "$PROJECT_ROOT/.env" "DATA_ROOT" "$DATA_ROOT"
        update_env_values "$PROJECT_ROOT/.env" "PROXY_TYPE" "$PROXY_TYPE"

        if [ "$PROXY_TYPE" = "traefik" ]; then
            if [ -z "${TRAEFIK_NETWORK:-}" ]; then
                local detected_net
                detected_net=$(prompt_traefik_network "traefik")
                update_env_values "$PROJECT_ROOT/.env" "TRAEFIK_NETWORK" "$detected_net"
            fi

            if [ -z "${SSL_MODE:-}" ]; then
                local chosen_ssl
                chosen_ssl=$(_prompt_ssl_mode "direct")
                update_env_values "$PROJECT_ROOT/.env" "SSL_MODE" "$chosen_ssl"
            fi
            
            # Reload env after updates
            load_env || true

            if [ -z "${API_DOMAIN:-}" ]; then
                api_domain=$(_prompt_domain_with_validation "API_DOMAIN (Traefik Host)" "api.statechecker.domain.de" "api.statechecker.example.com")
                update_env_values "$PROJECT_ROOT/.env" "API_DOMAIN" "$api_domain"
            fi
            if [ -z "${WEB_DOMAIN:-}" ]; then
                web_domain=$(_prompt_domain_with_validation "WEB_DOMAIN (Traefik Host)" "statechecker.domain.de" "statechecker.example.com")
                update_env_values "$PROJECT_ROOT/.env" "WEB_DOMAIN" "$web_domain"
            fi
            if [ -z "${PHPMYADMIN_DOMAIN:-}" ]; then
                pma_domain=$(_prompt_domain_with_validation "PHPMYADMIN_DOMAIN (Traefik Host)" "pma.statechecker.domain.de" "pma.statechecker.example.com")
                update_env_values "$PROJECT_ROOT/.env" "PHPMYADMIN_DOMAIN" "$pma_domain"
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

    # Read final proxy/SSL settings for stack generation
    local proxy_type ssl_mode include_pma
    proxy_type=$(grep '^PROXY_TYPE=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    ssl_mode=$(grep '^SSL_MODE=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    local pma_replicas
    pma_replicas=$(grep '^PHPMYADMIN_REPLICAS=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
    include_pma="true"
    [ "${pma_replicas:-0}" = "0" ] && include_pma="false"

    local enable_backup_network
    enable_backup_network=$(grep '^ENABLE_BACKUP_NETWORK=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')

    if [ -n "$enable_backup_network" ]; then
        if _is_truthy "$enable_backup_network"; then
            enable_backup_network="true"
        else
            enable_backup_network="false"
        fi
    else
        enable_backup_network="false"
        if _prompt_yes_no "Enable central backup integration (attach DB to backup-net)?" "N"; then
            if prompt_backup_network >/dev/null; then
                enable_backup_network="true"
            else
                echo "[WARN] Cannot enable backup integration because 'backup-net' is missing." >&2
                echo "       Deploy swarm-backup-restore first so it can create the network." >&2
                enable_backup_network="false"
            fi
        fi
    fi

    if [ "$enable_backup_network" = "true" ]; then
        if ! docker network inspect "backup-net" >/dev/null 2>&1; then
            echo "[WARN] Backup network 'backup-net' not found" >&2
            echo "       Deploy swarm-backup-restore first so it can create the network." >&2
            enable_backup_network="false"
        fi
    fi

    update_env_values "$PROJECT_ROOT/.env" "ENABLE_BACKUP_NETWORK" "$enable_backup_network"

    echo "" >&2
    echo "[BUILD] Generating swarm-stack.yml from templates..." >&2
    backup_existing_files "$PROJECT_ROOT"
    build_stack_file "${proxy_type:-traefik}" "$PROJECT_ROOT" "${ssl_mode:-direct}" "$include_pma" "true"
    
    # Replace Traefik network placeholder with actual network name
    if [ "${proxy_type:-traefik}" = "traefik" ]; then
        local traefik_net
        traefik_net=$(grep '^TRAEFIK_NETWORK=' "$PROJECT_ROOT/.env" 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d '"')
        traefik_net="${traefik_net:-traefik}"
        update_stack_network "$PROJECT_ROOT/swarm-stack.yml" "$traefik_net"
    fi

    update_stack_backup_network "$PROJECT_ROOT/swarm-stack.yml" "${enable_backup_network:-false}"

    echo "" >&2
    echo "==========================" >&2
    echo "  Secrets" >&2
    echo "==========================" >&2
    echo "" >&2

    echo "How do you want to create Docker secrets?" >&2
    echo "1) Edit secrets.env and create secrets from it (recommended)" >&2
    echo "2) Create secrets interactively" >&2
    echo "3) Skip for now" >&2
    echo "" >&2
    read_prompt "Your choice (1-3) [1]: " secrets_mode
    secrets_mode="${secrets_mode:-1}"

    case "$secrets_mode" in
        1)
            local secrets_file="$PROJECT_ROOT/secrets.env"
            local secrets_template="$SCRIPT_DIR/secrets.env.template"
            if [ ! -f "$secrets_file" ]; then
                if [ -f "$secrets_template" ]; then
                    cp "$secrets_template" "$secrets_file"
                    echo "[OK] Created secrets.env from template." >&2
                else
                    echo "[ERROR] Missing secrets template: $secrets_template" >&2
                fi
            fi

            if [ -z "${WIZARD_EDITOR:-}" ]; then
                wizard_choose_editor || true
            fi
            if [ -n "${WIZARD_EDITOR:-}" ] && [ -f "$secrets_file" ]; then
                wizard_edit_file "$secrets_file" "$WIZARD_EDITOR"
            fi

            create_secrets_from_env_file "secrets.env" "$SCRIPT_DIR/secrets.env.template" || true
            ;;
        2)
            create_required_secrets_menu
            echo "" >&2
            check_required_secrets || true

            read_prompt "Create optional secrets now (Telegram/Email/Google Drive)? (y/N): " create_optional
            if [[ "$create_optional" =~ ^[Yy]$ ]]; then
                create_optional_secrets_menu
            fi
            ;;
        *)
            echo "[INFO] Skipping secrets creation. You can create secrets later from the main menu."
            ;;
    esac

    if ! check_required_secrets; then
        echo "" >&2
        echo "[WARN] Some required secrets are still missing. Stack deploy may fail until they exist." >&2
    fi

    mark_setup_complete

    echo "" >&2
    read_prompt "Deploy the stack now? (Y/n): " deploy_now
    if [[ ! "$deploy_now" =~ ^[Nn]$ ]]; then
        echo "" >&2
        deploy_stack || true

        if command -v check_deployment_health >/dev/null 2>&1; then
            echo ""
            echo "[INFO] Waiting 20s before the first health check (services may still be initializing)..."
            check_deployment_health "${STACK_NAME:-statechecker}" "${PROXY_TYPE:-traefik}" 20 "30m" "200" || true
        fi
    fi

    echo "" >&2
    echo "✅ Setup complete. You can now run ./quick-start.sh to manage the stack." >&2
}

main "$@"
