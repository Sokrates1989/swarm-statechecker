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
source "${SETUP_DIR}/modules/deployment-preflight.sh"
source "${SETUP_DIR}/modules/menu_handlers.sh"
source "${SETUP_DIR}/modules/wizard.sh"
source "${SETUP_DIR}/modules/config-builder.sh"

_run_quick_start_smoke_test() {
    # Validate Bash syntax plus Docker and Compose availability without mutation.
    local script
    while IFS= read -r -d '' script; do
        bash -n "$script"
    done < <(find "$SCRIPT_DIR" -type f -name '*.sh' -print0)

    command -v docker >/dev/null 2>&1 || { echo "[ERROR] Docker is not available"; return 1; }
    docker --version >/dev/null

    if command -v docker-compose >/dev/null 2>&1; then
        docker-compose --version >/dev/null
    else
        docker compose version >/dev/null
    fi

    bash "${SCRIPT_DIR}/tests/render-stack-smoke.sh"

    echo "[OK] Smoke test completed (Bash syntax + Docker/Compose stack rendering)."
}

case "${1:-}" in
    --smoke-test|-SmokeTest)
        _run_quick_start_smoke_test
        exit $?
        ;;
    --health)
        load_env || { echo "[ERROR] .env file not found"; exit 1; }
        check_stack_health
        exit $?
        ;;
    "")
        ;;
    *)
        echo "[ERROR] Unknown argument: $1"
        echo "Usage: ./quick-start.sh [--smoke-test|--health]"
        exit 2
        ;;
esac

echo "🔍 Swarm Statechecker - Quick Start"
echo "===================================="
echo ""

# Keep all first-run configuration in the authoritative Bash wizard.
if [ ! -f .setup-complete ]; then
    echo "⚠️  Setup wizard has not been completed (.setup-complete missing)"
    read -p "Run the setup wizard now? (Y/n): " run_wizard
    if [[ "$run_wizard" =~ ^[Nn]$ ]]; then
        echo "[INFO] Setup was not started."
        exit 0
    fi

    bash "$SETUP_DIR/setup-wizard.sh"
    echo ""

    if [ ! -f .setup-complete ]; then
        echo "[ERROR] Setup did not complete."
        exit 1
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
