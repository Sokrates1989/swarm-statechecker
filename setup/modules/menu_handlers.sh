#!/bin/bash
#
# menu_handlers.sh
#
# Module for handling menu actions in quick-start script

load_env() {
    # load_env
    # Loads environment variables from .env into the current shell.
    # Returns:
    # - 0 if .env exists and was loaded
    # - 1 if .env does not exist
    if [ -f .env ]; then
        set -a
        source .env
        set +a
        return 0
    else
        return 1
    fi
}

update_env_values() {
    # update_env_values
    # Updates (or inserts) a KEY=VALUE pair in a dotenv file.
    #
    # Arguments:
    # - $1: env file path
    # - $2: key
    # - $3: value
    local env_file="$1"
    local key="$2"
    local value="$3"

    if [ -z "$env_file" ] || [ -z "$key" ]; then
        return 1
    fi

    local quoted_value
    quoted_value="$value"
    quoted_value="${quoted_value//\\/\\\\}"
    quoted_value="${quoted_value//\"/\\\"}"
    quoted_value="${quoted_value//\$/\\$}"
    quoted_value="${quoted_value//\`/\\\`}" 
    quoted_value="\"${quoted_value}\""

    local line_replacement
    line_replacement="${key}=${quoted_value}"

    local sed_replacement
    sed_replacement=$(printf '%s' "$line_replacement" | sed 's/[\\&|]/\\\\&/g')

    if [ ! -f "$env_file" ]; then
        printf '%s\n' "$line_replacement" >> "$env_file"
        return 0
    fi

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${sed_replacement}|" "$env_file"
        else
            sed -i "s|^${key}=.*|${sed_replacement}|" "$env_file"
        fi
    else
        printf '%s\n' "$line_replacement" >> "$env_file"
    fi
}

deploy_stack() {
    # deploy_stack
    # Deploys the Docker Swarm stack using config-stack.yml.
    # Notes:
    # - Uses docker-compose config rendering so ${VAR} substitutions are resolved.
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "🚀 Deploying stack: $stack_name"
    echo ""
    
    if [ ! -f .env ]; then
        echo "❌ .env file not found. Please create it first."
        return 1
    fi
    
    load_env

    local compose_cmd
    if command -v docker-compose >/dev/null 2>&1; then
        compose_cmd=(docker-compose)
    elif docker compose version >/dev/null 2>&1; then
        compose_cmd=(docker compose)
    else
        echo "⚠️  Neither docker-compose nor 'docker compose' is available. Deploying raw stack file (env substitution may be incomplete)."
        docker stack deploy -c config-stack.yml "$stack_name"
        return $?
    fi

    local compose_env_opt=()
    if [ -f .env ] && "${compose_cmd[@]}" --help 2>/dev/null | grep -q -- '--env-file'; then
        compose_env_opt=(--env-file .env)
    fi

    docker stack deploy -c <("${compose_cmd[@]}" -f config-stack.yml "${compose_env_opt[@]}" config) "$stack_name"
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "✅ Stack deployed: $stack_name"
        echo ""
        echo "📋 Stack services:"
        docker stack services "$stack_name"
    else
        echo "❌ Failed to deploy stack"
    fi
}

# Helper: Wait for stack and its networks to be fully removed
# Usage: _wait_for_stack_removal <stack_name> [timeout_seconds]
_wait_for_stack_removal() {
    local stack_name="$1"
    local timeout="${2:-120}"
    local elapsed=0
    local interval=2
    
    echo ""
    echo "⏳ Waiting for stack '$stack_name' to be fully removed..."
    
    while [ $elapsed -lt $timeout ]; do
        # Check if stack still exists
        local stack_exists=false
        if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$stack_name"; then
            stack_exists=true
        fi
        
        # Check if any networks with stack prefix still exist
        local networks_exist=false
        if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${stack_name}_"; then
            networks_exist=true
        fi
        
        # If both stack and networks are gone, we're done
        if [ "$stack_exists" = false ] && [ "$networks_exist" = false ]; then
            echo "✅ Stack '$stack_name' and all its networks have been fully removed."
            return 0
        fi
        
        # Show progress
        if [ "$stack_exists" = true ]; then
            printf "\r   Stack services still removing... (%ds elapsed)" "$elapsed"
        elif [ "$networks_exist" = true ]; then
            printf "\r   Networks still removing... (%ds elapsed)       " "$elapsed"
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo ""
    echo "⚠️  Timeout reached. Stack may not be fully removed yet."
    echo "   Please check manually with: docker stack ls && docker network ls | grep ${stack_name}"
    return 1
}

remove_stack() {
    # remove_stack
    # Removes the Docker Swarm stack.
    load_env
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "🛑 Removing stack: $stack_name"
    docker stack rm "$stack_name"
    
    if [ $? -eq 0 ]; then
        _wait_for_stack_removal "$stack_name"
    else
        echo "❌ Failed to remove stack"
    fi
}

show_stack_status() {
    # show_stack_status
    # Displays docker stack services for the current stack.
    load_env
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "📋 Stack status: $stack_name"
    echo ""
    docker stack services "$stack_name" 2>/dev/null || echo "Stack not found or not running"
}

show_stack_logs() {
    # show_stack_logs
    # Interactive selection of which service logs to follow.
    load_env
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "Which service logs do you want to view?"
    echo "1) api"
    echo "2) check"
    echo "3) db"
    echo "4) All services"
    echo ""
    
    read -p "Select (1-4): " log_choice
    
    case $log_choice in
        1)
            docker service logs "${stack_name}_api" -f
            ;;
        2)
            docker service logs "${stack_name}_check" -f
            ;;
        3)
            docker service logs "${stack_name}_db" -f
            ;;
        4)
            local services
            services=$(docker service ls --filter "label=com.docker.stack.namespace=${stack_name}" --format '{{.Name}}' 2>/dev/null)
            if [ -z "$services" ]; then
                echo "Stack not found or no services running"
            else
                local svc
                for svc in $services; do
                    echo ""
                    echo "===== $svc ====="
                    docker service logs --tail 50 "$svc" 2>/dev/null || true
                done
            fi
            ;;
        *)
            echo "❌ Invalid selection"
            ;;
    esac
}

toggle_phpmyadmin() {
    # toggle_phpmyadmin
    # Toggles the phpMyAdmin service replica count between 0 and 1 and persists
    # PHPMYADMIN_REPLICAS in .env.
    load_env
    local stack_name="${STACK_NAME:-statechecker-server}"

    echo "🔁 Toggle phpMyAdmin service for stack: $stack_name"
    echo ""

    if ! docker service inspect "${stack_name}_phpmyadmin" >/dev/null 2>&1; then
        echo "phpMyAdmin service not found. Make sure the stack is deployed."
        return
    fi

    local current_replicas
    current_replicas=$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "${stack_name}_phpmyadmin" 2>/dev/null || echo "0")
    local new_replicas
    if [ "$current_replicas" -eq 0 ] 2>/dev/null; then
        new_replicas=1
    else
        new_replicas=0
    fi

    echo "Scaling ${stack_name}_phpmyadmin from $current_replicas to $new_replicas replicas..."
    docker service scale "${stack_name}_phpmyadmin=$new_replicas"

    if [ -f .env ]; then
        update_env_values ".env" "PHPMYADMIN_REPLICAS" "$new_replicas"
    fi

    if [ "$new_replicas" -eq 0 ] 2>/dev/null; then
        echo "phpMyAdmin is now DISABLED."
    else
        if [ -f .env ]; then
            local url
            url=$(grep '^PHPMYADMIN_URL=' .env 2>/dev/null | cut -d'=' -f2 | tr -d ' "')
            if [ -n "$url" ]; then
                echo "phpMyAdmin is now ENABLED. Access it via https://$url"
            else
                echo "phpMyAdmin is now ENABLED."
            fi
        else
            echo "phpMyAdmin is now ENABLED."
        fi
    fi
}

create_required_secrets_menu() {
    # create_required_secrets_menu
    # Interactive creator for required Docker secrets.
    echo ""
    echo "🔐 Create required secrets"
    echo ""
    
    if ! check_secret_exists "STATECHECKER_SERVER_AUTHENTICATION_TOKEN"; then
        read -p "Create STATECHECKER_SERVER_AUTHENTICATION_TOKEN? (Y/n): " create_auth
        if [[ ! "$create_auth" =~ ^[Nn]$ ]]; then
            create_secret_interactive "STATECHECKER_SERVER_AUTHENTICATION_TOKEN" "API authentication token"
        fi
    fi
    
    if ! check_secret_exists "STATECHECKER_SERVER_DB_ROOT_USER_PW"; then
        read -p "Create STATECHECKER_SERVER_DB_ROOT_USER_PW? (Y/n): " create_root
        if [[ ! "$create_root" =~ ^[Nn]$ ]]; then
            create_secret_interactive "STATECHECKER_SERVER_DB_ROOT_USER_PW" "MySQL root password"
        fi
    fi
    
    if ! check_secret_exists "STATECHECKER_SERVER_DB_USER_PW"; then
        read -p "Create STATECHECKER_SERVER_DB_USER_PW? (Y/n): " create_user
        if [[ ! "$create_user" =~ ^[Nn]$ ]]; then
            create_secret_interactive "STATECHECKER_SERVER_DB_USER_PW" "MySQL user password"
        fi
    fi
}

create_optional_secrets_menu() {
    # create_optional_secrets_menu
    # Interactive creator for optional Docker secrets.
    echo ""
    echo "🔐 Create optional secrets"
    echo ""
    
    read -p "Create Telegram bot token secret? (y/N): " create_telegram
    if [[ "$create_telegram" =~ ^[Yy]$ ]]; then
        create_secret_interactive "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN" "Telegram bot token"
    fi
    
    read -p "Create Email password secret? (y/N): " create_email
    if [[ "$create_email" =~ ^[Yy]$ ]]; then
        create_secret_interactive "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD" "Email SMTP password"
    fi
    
    read -p "Create Google Drive service account secret? (y/N): " create_gdrive
    if [[ "$create_gdrive" =~ ^[Yy]$ ]]; then
        echo "For Google Drive, you need to provide the JSON file path"
        read -p "Path to service account JSON file: " json_path
        if [ -f "$json_path" ]; then
            create_secret_from_file "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON" "$json_path"
        else
            echo "❌ File not found: $json_path"
        fi
    fi
}

show_main_menu() {
     # show_main_menu
     # Main interactive menu loop.
     local choice
     
     while true; do
        local MENU_NEXT=1
        local MENU_DEPLOY=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_REMOVE=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_STATUS=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_LOGS=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))

        local MENU_SECRETS_CHECK=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_SECRETS_CREATE_REQUIRED=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_SECRETS_FROM_FILE=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_SECRETS_CREATE_OPTIONAL=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))
        local MENU_SECRETS_LIST=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))

        local MENU_TOGGLE_PHPMYADMIN=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))

        local MENU_CICD=$MENU_NEXT; MENU_NEXT=$((MENU_NEXT+1))

        local MENU_EXIT=$MENU_NEXT

         echo ""
         echo "================ Main Menu ================"
         echo ""
         echo "Deployment:"
        echo "  ${MENU_DEPLOY}) Deploy stack"
        echo "  ${MENU_REMOVE}) Remove stack"
        echo "  ${MENU_STATUS}) Show stack status"
        echo "  ${MENU_LOGS}) View service logs"
         echo ""
         echo "Secrets:"
        echo "  ${MENU_SECRETS_CHECK}) Check required secrets"
        echo "  ${MENU_SECRETS_CREATE_REQUIRED}) Create required secrets"
        echo "  ${MENU_SECRETS_FROM_FILE}) Create secrets from secrets.env file"
        echo "  ${MENU_SECRETS_CREATE_OPTIONAL}) Create optional secrets (Telegram, Email, Google Drive)"
        echo "  ${MENU_SECRETS_LIST}) List all secrets"
         echo ""
         echo "Management:"
        echo "  ${MENU_TOGGLE_PHPMYADMIN}) Toggle phpMyAdmin (enable/disable)"
         echo ""
         echo "CI/CD:"
        echo "  ${MENU_CICD}) GitHub Actions CI/CD helper"
         echo ""
        echo "  ${MENU_EXIT}) Exit"
         echo ""
         
        read -p "Your choice (1-${MENU_EXIT}): " choice
         
         case $choice in
            ${MENU_DEPLOY})
                 deploy_stack
                 ;;
            ${MENU_REMOVE})
                 remove_stack
                 ;;
            ${MENU_STATUS})
                 show_stack_status
                 ;;
            ${MENU_LOGS})
                 show_stack_logs
                 ;;
            ${MENU_SECRETS_CHECK})
                 check_required_secrets
                 check_optional_secrets
                 ;;
            ${MENU_SECRETS_CREATE_REQUIRED})
                 create_required_secrets_menu
                 ;;
            ${MENU_SECRETS_FROM_FILE})
                 create_secrets_from_env_file "secrets.env" "setup/secrets.env.template"
                 ;;
            ${MENU_SECRETS_CREATE_OPTIONAL})
                 create_optional_secrets_menu
                 ;;
            ${MENU_SECRETS_LIST})
                 list_secrets
                 ;;
            ${MENU_TOGGLE_PHPMYADMIN})
                 toggle_phpmyadmin
                 ;;
            ${MENU_CICD})
                 run_ci_cd_github_helper
                 ;;
            ${MENU_EXIT})
                 echo "👋 Goodbye!"
                 exit 0
                 ;;
             *)
                 echo "❌ Invalid selection"
                 ;;
         esac
     done
 }
