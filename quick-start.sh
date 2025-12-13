#!/bin/bash
#
# quick-start.sh
#
# Quick start tool for Swarm Statechecker:
# 1. Checks Docker Swarm
# 2. Manages secrets
# 3. Manages stack deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_DIR="${SCRIPT_DIR}/setup"

# Source modules
source "${SETUP_DIR}/modules/docker_helpers.sh"
source "${SETUP_DIR}/modules/ci-cd-github.sh"
source "${SETUP_DIR}/modules/menu_handlers.sh"

echo "🔍 Swarm Statechecker - Quick Start"
echo "===================================="
echo ""

# Docker Swarm availability check
if ! check_docker_swarm; then
    exit 1
fi
echo ""

# Docker Compose check
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose is not available!"
    echo "📥 Please install a current Docker version with Compose plugin"
    exit 1
fi
echo "✅ Docker Compose is available"
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "⚠️  .env file not found"
    echo ""
    if [ -f setup/.env.template ]; then
        read -p "Create .env from template? (Y/n): " create_env
        if [[ ! "$create_env" =~ ^[Nn]$ ]]; then
            cp setup/.env.template .env
            if ! grep -q '^TRAEFIK_NETWORK_NAME=' .env 2>/dev/null; then
                preferred=("traefik-public" "traefik_public" "traefik")
                networks=$(docker network ls --filter driver=overlay --format "{{.Name}}" 2>/dev/null || true)
                for n in "${preferred[@]}"; do
                    if echo "$networks" | grep -qx "$n"; then
                        update_env_values ".env" "TRAEFIK_NETWORK_NAME" "$n"
                        echo "✅ Auto-detected common Traefik network: $n (saved to .env)"
                        break
                    fi
                done
            fi
            echo "✅ .env created from template"
            echo "⚠️  Please edit .env with your configuration before deploying"
            echo ""

            EDITOR_CMD="${EDITOR:-nano}"
            if ! command -v "$EDITOR_CMD" >/dev/null 2>&1; then
                EDITOR_CMD="vi"
            fi
            read -p "Open .env now in $EDITOR_CMD? (Y/n): " open_env
            if [[ ! "$open_env" =~ ^[Nn]$ ]]; then
                "$EDITOR_CMD" .env
            fi
        fi
    fi
fi

# Check required secrets
echo "🔐 Checking secrets..."
if ! check_required_secrets; then
    echo ""
    echo "⚠️  Some required secrets are missing"
    echo "How do you want to create secrets?"
    echo "1) Create from secrets.env file"
    echo "2) Create interactively"
    echo ""
    read -p "Your choice (1-2) [2]: " create_mode
    create_mode="${create_mode:-2}"
    if [ "$create_mode" = "1" ]; then
        create_secrets_from_env_file "secrets.env" "setup/secrets.env.template" || exit 1
    else
        create_required_secrets_menu
    fi
fi
check_optional_secrets
echo ""

# Show main menu
show_main_menu
