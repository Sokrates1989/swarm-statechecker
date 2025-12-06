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
source "${SETUP_DIR}/modules/menu_handlers.sh"

echo "🔍 Swarm Statechecker - Quick Start"
echo "===================================="
echo ""

# Docker Swarm availability check
if ! check_docker_swarm; then
    exit 1
fi
echo ""

# Check if .env exists
if [ ! -f .env ]; then
    echo "⚠️  .env file not found"
    echo ""
    if [ -f setup/.env.template ]; then
        read -p "Create .env from template? (Y/n): " create_env
        if [[ ! "$create_env" =~ ^[Nn]$ ]]; then
            cp setup/.env.template .env
            echo "✅ .env created from template"
            echo "⚠️  Please edit .env with your configuration before deploying"
            echo ""
        fi
    fi
fi

# Check required secrets
echo "🔐 Checking secrets..."
if ! check_required_secrets; then
    echo ""
    echo "⚠️  Some required secrets are missing"
    read -p "Create them now? (Y/n): " create_secrets
    if [[ ! "$create_secrets" =~ ^[Nn]$ ]]; then
        create_required_secrets_menu
    fi
fi
check_optional_secrets
echo ""

# Show main menu
show_main_menu
