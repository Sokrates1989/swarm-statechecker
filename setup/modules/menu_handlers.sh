#!/bin/bash
#
# menu_handlers.sh
#
# Module for handling menu actions in quick-start script

load_env() {
    if [ -f .env ]; then
        set -a
        source .env
        set +a
        return 0
    else
        return 1
    fi
}

deploy_stack() {
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "🚀 Deploying stack: $stack_name"
    echo ""
    
    if [ ! -f .env ]; then
        echo "❌ .env file not found. Please create it first."
        return 1
    fi
    
    load_env
    
    docker stack deploy -c <(docker-compose -f config-stack.yml config) "$stack_name"
    
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

remove_stack() {
    load_env
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "🛑 Removing stack: $stack_name"
    docker stack rm "$stack_name"
    
    if [ $? -eq 0 ]; then
        echo "✅ Stack removed: $stack_name"
    else
        echo "❌ Failed to remove stack"
    fi
}

show_stack_status() {
    load_env
    local stack_name="${STACK_NAME:-statechecker-server}"
    
    echo "📋 Stack status: $stack_name"
    echo ""
    docker stack services "$stack_name" 2>/dev/null || echo "Stack not found or not running"
}

show_stack_logs() {
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
            docker service logs "${stack_name}_api" &
            docker service logs "${stack_name}_check" &
            docker service logs "${stack_name}_db" &
            wait
            ;;
        *)
            echo "❌ Invalid selection"
            ;;
    esac
}

toggle_phpmyadmin() {
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
        if grep -q '^PHPMYADMIN_REPLICAS=' .env; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/^PHPMYADMIN_REPLICAS=.*/PHPMYADMIN_REPLICAS=$new_replicas/" .env
            else
                sed -i "s/^PHPMYADMIN_REPLICAS=.*/PHPMYADMIN_REPLICAS=$new_replicas/" .env
            fi
        else
            echo "PHPMYADMIN_REPLICAS=$new_replicas" >> .env
        fi
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
    local choice
    
    while true; do
        echo ""
        echo "Choose an option:"
        echo "1) Deploy stack"
        echo "2) Remove stack"
        echo "3) Show stack status"
        echo "4) View service logs"
        echo "5) Check required secrets"
        echo "6) Create required secrets"
        echo "7) Create optional secrets (Telegram, Email, Google Drive)"
        echo "8) List all secrets"
        echo "9) Toggle phpMyAdmin (enable/disable)"
        echo "10) Exit"
        echo ""
        
        read -p "Your choice (1-10): " choice
        
        case $choice in
            1)
                deploy_stack
                ;;
            2)
                remove_stack
                ;;
            3)
                show_stack_status
                ;;
            4)
                show_stack_logs
                ;;
            5)
                check_required_secrets
                check_optional_secrets
                ;;
            6)
                create_required_secrets_menu
                ;;
            7)
                create_optional_secrets_menu
                ;;
            8)
                list_secrets
                ;;
            9)
                toggle_phpmyadmin
                ;;
            10)
                echo "👋 Goodbye!"
                exit 0
                ;;
            *)
                echo "❌ Invalid selection"
                ;;
        esac
    done
}
