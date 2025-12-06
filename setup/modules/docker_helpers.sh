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
