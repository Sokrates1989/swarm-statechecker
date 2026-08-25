#!/bin/bash
#
# deployment-preflight.sh
#
# Read-only validation for Statechecker deployment inputs and Swarm resources.
# It must run before placeholder-secret creation or stack deployment.

DEPLOYMENT_PREFLIGHT_FAILURES=0

_preflight_error() {
    # Record and print one actionable preflight failure.
    local message="$1"
    DEPLOYMENT_PREFLIGHT_FAILURES=$((DEPLOYMENT_PREFLIGHT_FAILURES + 1))
    printf '[ERROR] %s\n' "$message" >&2
}

_preflight_env_value() {
    # Read one dotenv value without evaluating shell syntax.
    local env_file="$1"
    local key="$2"
    local line value

    line=$(grep -m 1 -E "^${key}=" "$env_file" 2>/dev/null || true)
    value="${line#*=}"
    value="${value%$'\r'}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s' "$value"
}

_preflight_require_env_value() {
    # Require one non-empty key in a dotenv file.
    local env_file="$1"
    local key="$2"

    if [ -z "$(_preflight_env_value "$env_file" "$key")" ]; then
        _preflight_error "Required environment value is missing: ${key}"
        return 1
    fi
    return 0
}

_preflight_reject_placeholder_domain() {
    # Reject the hostnames shipped only as setup examples.
    local env_file="$1"
    local key="$2"
    local value
    value=$(_preflight_env_value "$env_file" "$key")

    case "$value" in
        api.statechecker.domain.de|statechecker.domain.de|pma.statechecker.domain.de|\
        api.statechecker.yourdomain.com|statechecker.yourdomain.com|pma.statechecker.yourdomain.com)
            _preflight_error "Replace placeholder ${key} with a real hostname: ${value}"
            return 1
            ;;
    esac
    return 0
}

preflight_environment_contract() {
    # Validate the static .env contract without contacting Docker.
    local env_file="$1"
    local failures_before="$DEPLOYMENT_PREFLIGHT_FAILURES"

    if [ ! -f "$env_file" ]; then
        _preflight_error "Environment file not found: ${env_file}"
        return 1
    fi

    local key
    for key in STACK_NAME DATA_ROOT DB_NAME DB_USER PROXY_TYPE IMAGE_NAME IMAGE_VERSION WEB_IMAGE_NAME WEB_IMAGE_VERSION KEYCLOAK_URL KEYCLOAK_REALM KEYCLOAK_CLIENT_ID KEYCLOAK_CLIENT_ID_WEB; do
        _preflight_require_env_value "$env_file" "$key" || true
    done

    local image_version web_image_version proxy_type pma_replicas
    image_version=$(_preflight_env_value "$env_file" "IMAGE_VERSION")
    web_image_version=$(_preflight_env_value "$env_file" "WEB_IMAGE_VERSION")
    proxy_type=$(_preflight_env_value "$env_file" "PROXY_TYPE")
    pma_replicas=$(_preflight_env_value "$env_file" "PHPMYADMIN_REPLICAS")

    if [ "$image_version" = "latest" ] || [ "$web_image_version" = "latest" ]; then
        _preflight_error "Mutable 'latest' image tags are not supported; configure explicit versions."
    fi

    local keycloak_url
    keycloak_url=$(_preflight_env_value "$env_file" "KEYCLOAK_URL")
    case "$keycloak_url" in
        https://keycloak.domain.de|https://keycloak.domain.de/|\
        https://keycloak.yourdomain.com|https://keycloak.yourdomain.com/)
            _preflight_error "Replace placeholder KEYCLOAK_URL with the real Keycloak URL: ${keycloak_url}"
            ;;
    esac

    case "$proxy_type" in
        traefik)
            for key in TRAEFIK_NETWORK API_DOMAIN WEB_DOMAIN; do
                _preflight_require_env_value "$env_file" "$key" || true
            done
            _preflight_reject_placeholder_domain "$env_file" "API_DOMAIN" || true
            _preflight_reject_placeholder_domain "$env_file" "WEB_DOMAIN" || true
            if [ "${pma_replicas:-0}" != "0" ]; then
                _preflight_require_env_value "$env_file" "PHPMYADMIN_DOMAIN" || true
                _preflight_reject_placeholder_domain "$env_file" "PHPMYADMIN_DOMAIN" || true
            fi
            ;;
        none)
            for key in API_PORT WEB_PORT; do
                _preflight_require_env_value "$env_file" "$key" || true
            done
            if [ "${pma_replicas:-0}" != "0" ]; then
                _preflight_require_env_value "$env_file" "PHPMYADMIN_PORT" || true
            fi
            ;;
        *)
            _preflight_error "PROXY_TYPE must be 'traefik' or 'none'."
            ;;
    esac

    [ "$DEPLOYMENT_PREFLIGHT_FAILURES" -eq "$failures_before" ]
}

preflight_stack_contract() {
    # Validate generated service, network, secret, and placeholder contracts.
    local stack_file="$1"
    local failures_before="$DEPLOYMENT_PREFLIGHT_FAILURES"

    if [ ! -f "$stack_file" ]; then
        _preflight_error "Generated stack file not found: ${stack_file}"
        return 1
    fi

    if grep -q '###[A-Z_]*###' "$stack_file"; then
        _preflight_error "Generated stack still contains template placeholders."
    fi

    local service
    for service in api check db db-migration web; do
        if ! grep -q -E "^  ${service}:" "$stack_file"; then
            _preflight_error "Generated stack is missing required service: ${service}"
        fi
    done

    if ! grep -q -E '^  backend:' "$stack_file"; then
        _preflight_error "Generated stack is missing the backend network."
    fi

    local secret
    for secret in \
        STATECHECKER_SERVER_AUTHENTICATION_TOKEN \
        STATECHECKER_SERVER_DB_ROOT_USER_PW \
        STATECHECKER_SERVER_DB_USER_PW \
        STATECHECKER_SERVER_KEYCLOAK_CLIENT_SECRET; do
        if ! grep -q "$secret" "$stack_file"; then
            _preflight_error "Generated stack is missing required secret reference: ${secret}"
        fi
    done

    [ "$DEPLOYMENT_PREFLIGHT_FAILURES" -eq "$failures_before" ]
}

preflight_swarm_resources() {
    # Validate required Docker secrets and the selected external network.
    local env_file="$1"
    local failures_before="$DEPLOYMENT_PREFLIGHT_FAILURES"
    local proxy_type traefik_network

    if ! command -v docker >/dev/null 2>&1; then
        _preflight_error "Docker CLI is not available."
        return 1
    fi

    if ! check_required_secrets; then
        _preflight_error "One or more required Docker secrets are missing."
    fi

    proxy_type=$(_preflight_env_value "$env_file" "PROXY_TYPE")
    if [ "$proxy_type" = "traefik" ]; then
        traefik_network=$(_preflight_env_value "$env_file" "TRAEFIK_NETWORK")
        if [ -n "$traefik_network" ] && ! docker network inspect "$traefik_network" >/dev/null 2>&1; then
            _preflight_error "External Traefik network does not exist: ${traefik_network}"
        fi
    fi

    [ "$DEPLOYMENT_PREFLIGHT_FAILURES" -eq "$failures_before" ]
}

preflight_rendered_stack() {
    # Reject unresolved variables and mutable image tags after Compose rendering.
    local rendered_stack="$1"
    local failures_before="$DEPLOYMENT_PREFLIGHT_FAILURES"

    preflight_stack_contract "$rendered_stack" || true

    if grep -q '\${[^}]*}' "$rendered_stack"; then
        _preflight_error "Rendered stack still contains unresolved environment variables."
    fi
    if grep -q -E 'image:[[:space:]]+[^[:space:]]+:latest([[:space:]]|$)' "$rendered_stack"; then
        _preflight_error "Rendered stack contains a mutable 'latest' image tag."
    fi

    [ "$DEPLOYMENT_PREFLIGHT_FAILURES" -eq "$failures_before" ]
}

run_deployment_preflight() {
    # Run every read-only check required before deployment-side mutations.
    local env_file="${1:-.env}"
    local stack_file="${2:-swarm-stack.yml}"

    DEPLOYMENT_PREFLIGHT_FAILURES=0
    printf '\n[PREFLIGHT] Validating deployment inputs...\n'

    preflight_environment_contract "$env_file" || true
    preflight_stack_contract "$stack_file" || true
    preflight_swarm_resources "$env_file" || true

    if [ "$DEPLOYMENT_PREFLIGHT_FAILURES" -ne 0 ]; then
        printf '[ERROR] Deployment preflight failed with %s problem(s).\n' "$DEPLOYMENT_PREFLIGHT_FAILURES" >&2
        return 1
    fi

    printf '[OK] Deployment inputs, required secrets, and networks are valid.\n'
    return 0
}
