#!/bin/bash

# GitHub Actions CI/CD helper for swarm deployment repositories

_ci_cd_github_detect_repo_url() {
    if command -v git >/dev/null 2>&1; then
        local url
        url=$(git remote get-url origin 2>/dev/null || true)
        if [ -n "$url" ]; then
            echo "$url"
            return 0
        fi
    fi

    echo ""
}

_ci_cd_github_to_web_url() {
    local url="$1"

    if [ -z "$url" ]; then
        echo ""
        return 0
    fi

    if echo "$url" | grep -qE '^git@github.com:'; then
        url="https://github.com/${url#git@github.com:}"
    fi

    if echo "$url" | grep -qE '^https?://github.com/'; then
        url="${url%.git}"
        echo "$url"
        return 0
    fi

    echo "$url"
}

_ci_cd_github_get_public_ip() {
    local ip=""

    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -fsS https://api.ipify.org 2>/dev/null || true)
    fi

    if [ -z "$ip" ] && command -v dig >/dev/null 2>&1; then
        ip=$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -n 1 || true)
    fi

    if [ -z "$ip" ] && command -v wget >/dev/null 2>&1; then
        ip=$(wget -qO- https://api.ipify.org 2>/dev/null || true)
    fi

    echo "$ip"
}

_ci_cd_github_get_env_value() {
    local file_path="$1"
    local key="$2"

    if [ ! -f "$file_path" ]; then
        echo ""
        return 0
    fi

    local line
    line=$(grep "^${key}=" "$file_path" 2>/dev/null | head -n 1 || true)
    if [ -z "$line" ]; then
        echo ""
        return 0
    fi

    echo "${line#*=}" | tr -d '"'
}

_ci_cd_github_prompt_default() {
    local prompt_text="$1"
    local default_value="$2"

    local input
    read -p "$prompt_text [$default_value]: " input
    if [ -z "$input" ]; then
        echo "$default_value"
    else
        echo "$input"
    fi
}

_ci_cd_github_print_required_vars_and_secrets() {
    local suffix="$1"
    local deploy_path="$2"
    local stack_name="$3"
    local stack_file="$4"
    local image_name="$5"
    local ssh_host="$6"
    local ssh_port="$7"

    echo ""
    echo "=============================="
    echo "GitHub Actions configuration"
    echo "=============================="
    echo ""

    echo "Repository Variables (Settings -> Secrets and variables -> Actions -> Variables):"
    echo "  IMAGE_NAME${suffix}=${image_name}"
    echo "  STACK_NAME${suffix}=${stack_name}"
    echo "  STACK_FILE${suffix}=${stack_file}"
    echo "  DEPLOY_PATH${suffix}=${deploy_path}"

    echo ""
    echo "Repository Secrets (Settings -> Secrets and variables -> Actions -> Secrets):"
    echo "  SSH_HOST${suffix}=${ssh_host}"
    echo "  SSH_PORT${suffix}=${ssh_port}"
    echo "  SSH_USER${suffix}=<deploy-user>"
    echo "  SSH_PRIVATE_KEY${suffix}=<private key for deploy-user>"
    echo "  DOCKER_USERNAME${suffix}=<registry username>"
    echo "  DOCKER_PASSWORD${suffix}=<registry password/token>"
}

_ci_cd_github_prompt_env() {
    # _ci_cd_github_prompt_env
    # Prompts for environment-specific configuration.
    local env_name="$1"
    local suffix="$2"
    local default_path="$3"
    local default_stack="$4"
    local default_file="$5"
    local default_image="$6"
    local default_host="$7"
    local default_port="$8"

    echo ""
    echo "--- $env_name environment ---"
    
    local deploy_path stack_name stack_file image_name ssh_host ssh_port
    deploy_path=$(_ci_cd_github_prompt_default "DEPLOY_PATH" "$default_path")
    stack_name=$(_ci_cd_github_prompt_default "STACK_NAME" "$default_stack")
    stack_file=$(_ci_cd_github_prompt_default "STACK_FILE" "$default_file")
    image_name=$(_ci_cd_github_prompt_default "IMAGE_NAME" "$default_image")
    ssh_host=$(_ci_cd_github_prompt_default "SSH_HOST" "$default_host")
    ssh_port=$(_ci_cd_github_prompt_default "SSH_PORT" "$default_port")

    _ci_cd_github_print_required_vars_and_secrets "$suffix" "$deploy_path" "$stack_name" "$stack_file" "$image_name" "$ssh_host" "$ssh_port"
}

run_ci_cd_github_helper() {
    echo "🔧 GitHub Actions CI/CD Helper"
    echo "=============================="
    echo ""

    local repo_remote repo_web
    repo_remote=$(_ci_cd_github_detect_repo_url)
    repo_web=$(_ci_cd_github_to_web_url "$repo_remote")

    if [ -n "$repo_web" ]; then
        echo "Repository (detected): $repo_web"
        echo "Variables URL: ${repo_web}/settings/variables/actions"
        echo "Secrets URL:   ${repo_web}/settings/secrets/actions"
    else
        echo "Repository: (could not detect via git)"
    fi

    echo ""
    local public_ip
    public_ip=$(_ci_cd_github_get_public_ip)
    [ -n "$public_ip" ] && echo "Detected public IP (suggestion for SSH_HOST*): $public_ip" || echo "Public IP: (not detected)"

    echo ""
    echo "Which environment do you want to configure?"
    echo "1) main"
    echo "2) dev"
    echo "3) both"
    echo ""
    read -p "Your choice (1-3) [3]: " env_choice
    env_choice="${env_choice:-3}"

    local env_file="$(pwd)/.env"
    [ ! -f "$env_file" ] && echo "⚠️  .env not found. Auto-detection limited."

    local default_stack_name
    default_stack_name=$(_ci_cd_github_get_env_value "$env_file" "STACK_NAME")
    default_stack_name="${default_stack_name:-$(basename "$(pwd)")}"

    local default_image_name
    default_image_name=$(_ci_cd_github_get_env_value "$env_file" "IMAGE_NAME")

    local default_stack_file="swarm-stack.yml"
    [ -f "docker-compose.yml" ] && default_stack_file="docker-compose.yml"

    if [ "$env_choice" = "1" ] || [ "$env_choice" = "3" ]; then
        _ci_cd_github_prompt_env "main" "" "$(pwd)" "$default_stack_name" "$default_stack_file" "$default_image_name" "${public_ip:-}" "22"
    fi

    if [ "$env_choice" = "2" ] || [ "$env_choice" = "3" ]; then
        _ci_cd_github_prompt_env "dev" "_DEV" "$(pwd)" "${default_stack_name}-dev" "$default_stack_file" "$default_image_name" "${public_ip:-}" "22"
    fi

    echo -e "\nServer-side checklist:\n  - Ensure SSH user is in docker group\n  - Ensure SSH user can write to DEPLOY_PATH\n"
}
