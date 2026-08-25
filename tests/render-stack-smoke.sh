#!/bin/bash
#
# render-stack-smoke.sh
#
# Generate and parse every supported routing mode without contacting Swarm.

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_BUILDER="${REPOSITORY_ROOT}/setup/modules/config-builder.sh"
ENVIRONMENT_TEMPLATE="${REPOSITORY_ROOT}/setup/.env.template"

if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_COMMAND=(docker-compose)
elif docker compose version >/dev/null 2>&1; then
    COMPOSE_COMMAND=(docker compose)
else
    echo "[ERROR] Docker Compose is required for stack rendering." >&2
    exit 1
fi

TEMPORARY_PARENT="${TMPDIR:-/tmp}"
TEMPORARY_ROOT=$(mktemp -d "${TEMPORARY_PARENT}/statechecker-stack-smoke.XXXXXX")

cleanup_temporary_root() {
    # Remove only the dedicated directory created by this smoke test.
    case "$TEMPORARY_ROOT" in
        "${TEMPORARY_PARENT}/statechecker-stack-smoke."*)
            [ ! -d "$TEMPORARY_ROOT" ] || rm -r -- "$TEMPORARY_ROOT"
            ;;
        *)
            echo "[WARN] Refusing to remove unexpected path: ${TEMPORARY_ROOT}" >&2
            ;;
    esac
}

trap cleanup_temporary_root EXIT

mkdir -p "${TEMPORARY_ROOT}/project/setup"
cp -R "${REPOSITORY_ROOT}/setup/compose-modules" "${TEMPORARY_ROOT}/project/setup/"

# shellcheck source=../setup/modules/config-builder.sh
source "$CONFIG_BUILDER"

render_mode() {
    # Generate and validate one proxy/SSL combination.
    local proxy_type="$1"
    local ssl_mode="$2"
    local project_root="${TEMPORARY_ROOT}/project"

    build_stack_file "$proxy_type" "$project_root" "$ssl_mode" true true
    if [ "$proxy_type" = "traefik" ]; then
        update_stack_network "${project_root}/swarm-stack.yml" "traefik"
    fi

    "${COMPOSE_COMMAND[@]}" \
        --env-file "$ENVIRONMENT_TEMPLATE" \
        -f "${project_root}/swarm-stack.yml" \
        config --quiet
}

render_mode none direct
render_mode traefik direct
render_mode traefik proxy

echo "[OK] No-proxy, direct-TLS, and proxy-TLS stacks rendered successfully."
