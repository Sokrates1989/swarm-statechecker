#!/bin/bash
#
# health-check.sh
#
# Read-only Swarm convergence and external endpoint checks for Statechecker.

HEALTH_FAILURES=0

_health_error() {
    # Record and print one health-check failure.
    local message="$1"
    HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    printf '[ERROR] %s\n' "$message" >&2
}

_print_deployment_endpoints() {
    # Print endpoint URLs based on the selected proxy type.
    local proxy_type="$1"

    echo ""
    echo "[ENDPOINTS]"

    if [ "$proxy_type" = "none" ]; then
        echo "API:  http://127.0.0.1:${API_PORT:-8787}/health"
        echo "WEB:  http://127.0.0.1:${WEB_PORT:-8080}/"
        if [ "${PHPMYADMIN_REPLICAS:-0}" != "0" ]; then
            echo "PMA:  http://127.0.0.1:${PHPMYADMIN_PORT:-8081}/"
        fi
    else
        [ -n "${API_DOMAIN:-}" ] && echo "API:  https://${API_DOMAIN}/health"
        [ -n "${WEB_DOMAIN:-}" ] && echo "WEB:  https://${WEB_DOMAIN}/"
        if [ "${PHPMYADMIN_REPLICAS:-0}" != "0" ] && [ -n "${PHPMYADMIN_DOMAIN:-}" ]; then
            echo "PMA:  https://${PHPMYADMIN_DOMAIN}/"
        fi
    fi
}

_check_service_convergence() {
    # Require all persistent services to reach their desired replica counts.
    local stack_name="$1"
    local service_rows
    service_rows=$(docker stack services "$stack_name" --format '{{.Name}}|{{.Replicas}}' 2>/dev/null || true)

    if [ -z "$service_rows" ]; then
        _health_error "No services found for stack: ${stack_name}"
        return 1
    fi

    local api_found=0 check_found=0 db_found=0 web_found=0
    local service_name replicas service_suffix current desired
    while IFS='|' read -r service_name replicas; do
        [ -z "$service_name" ] && continue
        service_suffix="${service_name#${stack_name}_}"

        case "$service_suffix" in
            api) api_found=1 ;;
            check) check_found=1 ;;
            db) db_found=1 ;;
            web) web_found=1 ;;
            db-migration) continue ;;
        esac

        current="${replicas%%/*}"
        desired="${replicas##*/}"
        current="${current//[!0-9]/}"
        desired="${desired//[!0-9]/}"

        if [ -z "$current" ] || [ -z "$desired" ]; then
            _health_error "Could not parse replica state for ${service_name}: ${replicas}"
        elif [ "$current" -ne "$desired" ]; then
            _health_error "Service ${service_name} is incomplete: ${replicas}"
        fi
    done <<< "$service_rows"

    [ "$api_found" -eq 1 ] || _health_error "Required service is missing: ${stack_name}_api"
    [ "$check_found" -eq 1 ] || _health_error "Required service is missing: ${stack_name}_check"
    [ "$db_found" -eq 1 ] || _health_error "Required service is missing: ${stack_name}_db"
    [ "$web_found" -eq 1 ] || _health_error "Required service is missing: ${stack_name}_web"
}

_check_active_task_failures() {
    # Fail when an active desired task is rejected, failed, or shut down.
    local stack_name="$1"
    local task_rows
    task_rows=$(docker stack ps "$stack_name" --no-trunc --format '{{.Name}}|{{.DesiredState}}|{{.CurrentState}}|{{.Error}}' 2>/dev/null || true)

    local task_name desired_state current_state task_error
    while IFS='|' read -r task_name desired_state current_state task_error; do
        [ -z "$task_name" ] && continue
        if [[ "$desired_state" =~ ^(Running|Ready|Accepted)$ ]] && [[ "$current_state" =~ ^(Failed|Rejected|Shutdown) ]]; then
            _health_error "Task ${task_name} is ${current_state}${task_error:+: ${task_error}}"
        fi
    done <<< "$task_rows"

    local migration_service="${stack_name}_db-migration"
    if docker service inspect "$migration_service" >/dev/null 2>&1; then
        local migration_state
        migration_state=$(docker service ps "$migration_service" --no-trunc --format '{{.CurrentState}}' 2>/dev/null | head -n 1 || true)
        if [ -z "$migration_state" ]; then
            _health_error "Database migration service has no task state."
        elif [[ "$migration_state" =~ ^(Failed|Rejected|Shutdown) ]]; then
            _health_error "Database migration task is unhealthy: ${migration_state}"
        fi
    else
        _health_error "Required service is missing: ${migration_service}"
    fi
}

_check_http_endpoint() {
    # Require one external HTTP endpoint to return a successful response.
    local label="$1"
    local url="$2"
    local timeout_seconds="${HEALTH_HTTP_TIMEOUT_SECONDS:-10}"

    if ! curl --fail --silent --show-error --location --max-time "$timeout_seconds" --output /dev/null "$url"; then
        _health_error "${label} endpoint is unreachable or unhealthy: ${url}"
    else
        printf '[OK] %s endpoint: %s\n' "$label" "$url"
    fi
}

_check_external_endpoints() {
    # Check the API, web UI, and optional phpMyAdmin through operator-facing URLs.
    local proxy_type="$1"

    if ! command -v curl >/dev/null 2>&1; then
        _health_error "curl is required for external endpoint checks."
        return 1
    fi

    if [ "$proxy_type" = "none" ]; then
        _check_http_endpoint "API" "http://127.0.0.1:${API_PORT:-8787}/health"
        _check_http_endpoint "WEB" "http://127.0.0.1:${WEB_PORT:-8080}/"
        if [ "${PHPMYADMIN_REPLICAS:-0}" != "0" ]; then
            _check_http_endpoint "PMA" "http://127.0.0.1:${PHPMYADMIN_PORT:-8081}/"
        fi
    else
        _check_http_endpoint "API" "https://${API_DOMAIN}/health"
        _check_http_endpoint "WEB" "https://${WEB_DOMAIN}/"
        if [ "${PHPMYADMIN_REPLICAS:-0}" != "0" ]; then
            _check_http_endpoint "PMA" "https://${PHPMYADMIN_DOMAIN}/"
        fi
    fi
}

check_deployment_health() {
    # Check service convergence, task failures, and public endpoint reachability.
    local stack_name="$1"
    local proxy_type="$2"
    local wait_seconds="${3:-0}"
    local logs_since="${4:-10m}"
    local logs_tail="${5:-200}"

    [ -n "$stack_name" ] || { echo "[ERROR] Stack name is required"; return 1; }
    HEALTH_FAILURES=0

    echo ""
    echo "[HEALTH] Deployment Health Check"
    echo "================================="

    if [ "$wait_seconds" -gt 0 ] 2>/dev/null; then
        echo "[WAIT] Waiting ${wait_seconds}s for services to initialize..."
        sleep "$wait_seconds"
    fi

    echo ""
    echo "[STATUS] Stack services:"
    if ! docker stack services "$stack_name"; then
        _health_error "Stack not found or Docker could not read it: ${stack_name}"
    else
        _check_service_convergence "$stack_name" || true
        _check_active_task_failures "$stack_name" || true
    fi

    _print_deployment_endpoints "$proxy_type"
    echo ""
    echo "[HTTP] External reachability:"
    _check_external_endpoints "$proxy_type" || true

    if [ "$HEALTH_FAILURES" -ne 0 ]; then
        echo ""
        echo "[LOGS] Recent logs (since=${logs_since}, tail=${logs_tail})"
        tail_logs_all_services "$stack_name" "$logs_since" "$logs_tail"
        echo ""
        echo "[ERROR] Health check failed with ${HEALTH_FAILURES} problem(s)."
        return 1
    fi

    echo ""
    echo "[OK] Deployment is converged and externally reachable."
    return 0
}

tail_logs_all_services() {
    # Print recent logs for every service in a stack.
    local stack_name="$1"
    local since="${2:-10m}"
    local tail_lines="${3:-200}"
    local services

    services=$(docker service ls --filter "label=com.docker.stack.namespace=${stack_name}" --format '{{.Name}}' 2>/dev/null || true)
    if [ -z "$services" ]; then
        echo "[WARN] No services found for stack: $stack_name"
        return 0
    fi

    local service
    for service in $services; do
        echo ""
        echo "===== $service ====="
        docker service logs --since "$since" --tail "$tail_lines" "$service" 2>/dev/null || true
    done
}
