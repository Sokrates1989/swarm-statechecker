#!/bin/bash
#
# docker_helpers.sh
#
# Module for Docker-related helper functions for Swarm deployment

check_docker_swarm() {
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
    
    if [ "$swarm_status" != "active" ]; then
        echo "❌ Docker is not in Swarm mode!"
        echo "   Run 'docker swarm init' to initialize a swarm"
        return 1
    fi

    echo "✅ Docker Swarm is active"
    return 0
}

check_secret_exists() {
    local secret_name="$1"
    if docker secret inspect "$secret_name" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

create_secret_interactive() {
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
    
    echo "$secret_value" | docker secret create "$secret_name" -
    
    if [ $? -eq 0 ]; then
        echo "✅ Secret created: $secret_name"
        return 0
    else
        echo "❌ Failed to create secret: $secret_name"
        return 1
    fi
}

create_secret_from_file() {
    local secret_name="$1"
    local file_path="$2"
    
    if [ ! -f "$file_path" ]; then
        echo "❌ File not found: $file_path"
        return 1
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
        read -p "Secret '$secret_name' already exists. Delete and recreate? (y/N): " recreate
        if [[ "$recreate" =~ ^[Yy]$ ]]; then
            docker secret rm "$secret_name" >/dev/null 2>&1 || true
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

    if [ ! -f "$secrets_file" ]; then
        if [ -f "$template_file" ]; then
            cp "$template_file" "$secrets_file"
            echo "✅ Created $secrets_file from template: $template_file"
            echo "⚠️  Please edit $secrets_file and re-run this action."
            read -p "Open $secrets_file in editor now? (Y/n): " open_file
            if [[ ! "$open_file" =~ ^[Nn]$ ]]; then
                if command -v nano &> /dev/null; then
                    nano "$secrets_file"
                elif command -v vim &> /dev/null; then
                    vim "$secrets_file"
                else
                    echo "No editor found. Please edit $secrets_file manually."
                fi
            fi
            return 1
        fi

        echo "❌ Secrets template not found: $template_file"
        return 1
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
            if check_secret_exists "$key"; then
                read -p "Secret '$key' already exists. Delete and recreate? (y/N): " recreate
                if [[ "$recreate" =~ ^[Yy]$ ]]; then
                    docker secret rm "$key" >/dev/null 2>&1 || true
                else
                    continue
                fi
            fi
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
    echo "📋 Current secrets:"
    docker secret ls
}

check_required_secrets() {
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
