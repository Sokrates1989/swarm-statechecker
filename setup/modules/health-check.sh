#!/bin/bash
#
# health-check.sh
#
# Deployment health check helpers for Swarm Statechecker.

check_deployment_health() {
    # check_deployment_health
    # Runs a simple deployment health check for the stack.
    #
    # Arguments:
    # - $1: stack name
    # - $2: proxy type (traefik|none)
    # - $3: wait seconds (optional, default: 0)
    # - $4: logs since (optional, default: 10m)
    # - $5: logs tail (optional, default: 200)
    local stack_name="$1"
    local proxy_type="$2"
    local wait_seconds="${3:-0}"
    local logs_since="${4:-10m}"
    local logs_tail="${5:-200}"

    if [ -z "$stack_name" ]; then
        echo "❌ Stack name is required"
        return 1
    fi

    echo ""
    echo "[HEALTH] Deployment Health Check"
    echo "================================="
    echo ""

    if [ "$wait_seconds" -gt 0 ] 2>/dev/null; then
        echo "[WAIT] Waiting ${wait_seconds}s for services to initialize..."
        sleep "$wait_seconds"
        echo ""
    fi

    echo "[STATUS] Stack services:"
    docker stack services "$stack_name" 2>/dev/null
    if [ $? -ne 0 ]; then
        echo "[ERROR] Stack '$stack_name' not found"
        return 1
    fi

    echo ""
    echo "[TASKS] Service tasks:"
    docker stack ps "$stack_name" --format "table {{.Name}}\t{{.CurrentState}}\t{{.Error}}" 2>/dev/null || true

    local failed_tasks
    failed_tasks=$(docker stack ps "$stack_name" --format "{{.CurrentState}}" 2>/dev/null | grep -E "Failed|Rejected" | wc -l 2>/dev/null)
    failed_tasks=${failed_tasks:-0}

    if [ "$failed_tasks" -gt 0 ] 2>/dev/null; then
        echo ""
        echo "[WARN] $failed_tasks task(s) have failed"
        echo "       Check logs via the logs menu or: docker service logs ${stack_name}_api"
    fi

    echo ""
    echo "[ENDPOINTS]"

    if [ "$proxy_type" = "none" ]; then
        local api_port="${API_PORT:-8787}"
        local web_port="${WEB_PORT:-8080}"
        local pma_port="${PHPMYADMIN_PORT:-8081}"

        echo "API:  http://localhost:${api_port}"
        echo "WEB:  http://localhost:${web_port}"

        if [ "${PHPMYADMIN_REPLICAS:-0}" != "0" ]; then
            echo "PMA:  http://localhost:${pma_port}"
        fi
    else
        if [ -n "${API_URL:-}" ]; then
            echo "API:  https://${API_URL}"
        fi
        if [ -n "${WEB_URL:-}" ]; then
            echo "WEB:  https://${WEB_URL}"
        fi
        if [ "${PHPMYADMIN_REPLICAS:-0}" != "0" ] && [ -n "${PHPMYADMIN_URL:-}" ]; then
            echo "PMA:  https://${PHPMYADMIN_URL}"
        fi
    fi

    echo ""
    echo "[LOGS] Recent logs (since=${logs_since}, tail=${logs_tail})"
    tail_logs_all_services "$stack_name" "$logs_since" "$logs_tail"

    echo ""
    echo "[OK] Health check complete"
    return 0
}

tail_logs_all_services() {
    # tail_logs_all_services
    # Prints recent logs for all services in a stack.
    #
    # Arguments:
    # - $1: stack name
    # - $2: since (optional, default: 10m)
    # - $3: tail lines (optional, default: 200)
    local stack_name="$1"
    local since="${2:-10m}"
    local tail_lines="${3:-200}"

    local services
    services=$(docker service ls --filter "label=com.docker.stack.namespace=${stack_name}" --format '{{.Name}}' 2>/dev/null || true)

    if [ -z "$services" ]; then
        echo "[WARN] No services found for stack: $stack_name"
        return 0
    fi

    local svc
    for svc in $services; do
        echo ""
        echo "===== $svc ====="
        docker service logs --since "$since" --tail "$tail_lines" "$svc" 2>/dev/null || true
    done
}
