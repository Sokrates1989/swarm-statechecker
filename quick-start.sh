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

cd "$SCRIPT_DIR"

# Source modules
source "${SETUP_DIR}/modules/docker_helpers.sh"
source "${SETUP_DIR}/modules/ci-cd-github.sh"
source "${SETUP_DIR}/modules/health-check.sh"
source "${SETUP_DIR}/modules/menu_handlers.sh"
source "${SETUP_DIR}/modules/wizard.sh"
source "${SETUP_DIR}/modules/config-builder.sh"

echo "🔍 Swarm Statechecker - Quick Start"
echo "===================================="
echo ""

# Offer wizard-driven setup (recommended)
if [ ! -f .setup-complete ]; then
    echo "⚠️  Setup wizard has not been completed (.setup-complete missing)"
    echo "How do you want to set up configuration?"
    echo "1) Edit .env + secrets.env (copy from templates)"
    echo "2) Run guided setup wizard (recommended)"
    echo ""
    read -p "Your choice (1-2) [2]: " setup_mode
    setup_mode="${setup_mode:-2}"

    if [ "$setup_mode" = "1" ]; then
        if [ -z "${WIZARD_EDITOR:-}" ]; then
            wizard_choose_editor || exit 1
        fi

        if [ ! -f .env ] && [ -f setup/env-templates/.env.base.template ]; then
            build_env_file "traefik" "$SCRIPT_DIR"
        fi
        if [ -f .env ]; then
            wizard_edit_file "$(pwd)/.env" "$WIZARD_EDITOR"
        fi

        if [ ! -f secrets.env ] && [ -f setup/secrets.env.template ]; then
            cp setup/secrets.env.template secrets.env
        fi
        if [ -f secrets.env ]; then
            wizard_edit_file "$(pwd)/secrets.env" "$WIZARD_EDITOR"
        fi

        # Create secrets from secrets.env
        if [ -f secrets.env ]; then
            echo ""
            create_secrets_from_env_file "secrets.env" "setup/secrets.env.template" || true
        fi

        # Mark setup complete
        : > "$SCRIPT_DIR/.setup-complete"

        # Ask to deploy
        echo ""
        read -p "Deploy the stack now? (Y/n): " deploy_now
        if [[ ! "$deploy_now" =~ ^[Nn]$ ]]; then
            echo ""
            load_env || true
            deploy_stack || true

            if command -v check_deployment_health >/dev/null 2>&1; then
                echo ""
                echo "[INFO] Waiting 20s before the first health check (services may still be initializing)..."
                check_deployment_health "${STACK_NAME:-statechecker}" "${PROXY_TYPE:-traefik}" 20 "30m" "200" || true
            fi
        fi

        echo ""
        echo "✅ Setup complete. You can now run ./quick-start.sh to manage the stack."
        exit 0
    else
        if [ -f "$SETUP_DIR/setup-wizard.sh" ]; then
            read -p "Run setup wizard now? (Y/n): " run_wizard
            if [[ ! "$run_wizard" =~ ^[Nn]$ ]]; then
                bash "$SETUP_DIR/setup-wizard.sh"
                echo ""
            fi
        fi
    fi
fi

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
    if [ -f setup/env-templates/.env.base.template ]; then
        read -p "Create .env from template? (Y/n): " create_env
        if [[ ! "$create_env" =~ ^[Nn]$ ]]; then
            # Source config-builder if not already loaded
            if ! command -v build_env_file >/dev/null 2>&1; then
                source "${SETUP_DIR}/modules/config-builder.sh"
            fi
            build_env_file "traefik" "$SCRIPT_DIR"
            if ! grep -q '^TRAEFIK_NETWORK=' .env 2>/dev/null; then
                preferred=("traefik-public" "traefik_public" "traefik")
                networks=$(docker network ls --filter driver=overlay --format "{{.Name}}" 2>/dev/null || true)
                for n in "${preferred[@]}"; do
                    if echo "$networks" | grep -qx "$n"; then
                        update_env_values ".env" "TRAEFIK_NETWORK" "$n"
                        echo "✅ Auto-detected common Traefik network: $n (saved to .env)"
                        break
                    fi
                done
            fi
            echo "✅ .env created from template"
            echo ""

            echo "⚠️  Please run the setup wizard to configure deployment settings"
            echo ""
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
