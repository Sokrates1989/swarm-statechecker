#!/bin/bash
#
# menu_handlers.sh
#
# Module for handling menu actions in quick-start script

read_prompt() {
    local prompt="$1"
    local var_name="$2"

    if [[ -r /dev/tty ]]; then
        read -r -p "$prompt" "$var_name" < /dev/tty
    else
        read -r -p "$prompt" "$var_name"
    fi
}

_sanitize_env_file_statechecker_config() {
    # _sanitize_env_file_statechecker_config
    # Removes leftover multiline JSON blocks from older templates for STATECHECKER_SERVER_CONFIG.
    # Those lines are not valid dotenv syntax and can break both `source .env` and `docker compose --env-file`.
    if [ ! -f .env ]; then
        return 0
    fi

    if ! grep -q '^STATECHECKER_SERVER_CONFIG=' .env 2>/dev/null; then
        return 0
    fi

    if ! grep -q '^STATECHECKER_SERVER_CONFIG=.*\{.*' .env 2>/dev/null; then
        return 0
    fi

    local tmp_file
    tmp_file=".env.tmp.$$"

    awk '
        BEGIN { in_cfg=0 }
        {
            if (in_cfg == 1) {
                if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || $0 ~ /^#/ || $0 ~ /^\s*$/) {
                    in_cfg=0
                    print $0
                }
                next
            }

            if ($0 ~ /^STATECHECKER_SERVER_CONFIG=/) {
                print $0
                in_cfg=1
                next
            }

            print $0
        }
    ' .env > "$tmp_file"

    mv "$tmp_file" .env
    return 0
}

check_stack_health() {
    # check_stack_health
    # Runs a health check using setup/modules/health-check.sh.
    load_env
    local stack_name="${STACK_NAME:-statechecker}"
    local proxy_type="${PROXY_TYPE:-traefik}"

    local wait_seconds="${HEALTH_WAIT_SECONDS:-0}"
    local logs_since="${LOGS_SINCE:-30m}"
    local logs_tail="${LOGS_TAIL:-200}"

    if command -v check_deployment_health >/dev/null 2>&1; then
        check_deployment_health "$stack_name" "$proxy_type" "$wait_seconds" "$logs_since" "$logs_tail"
    else
        echo "❌ health-check.sh is not loaded (check_deployment_health missing)"
        return 1
    fi
}

_update_image_service() {
    # _update_image_service
    # Pulls image and updates services for a given image/tag.
    local img_name="$1"
    local img_tag="$2"
    local svc_prefix="$3"
    local env_key="$4"
    local stack_name="${STACK_NAME:-statechecker}"

    echo ""
    echo "Pulling: ${img_name}:${img_tag}"
    docker pull "${img_name}:${img_tag}" || true

    echo ""
    echo "Updating service(s)..."
    if [ "$svc_prefix" = "api_check" ]; then
        docker service update --image "${img_name}:${img_tag}" "${stack_name}_api" || true
        docker service update --image "${img_name}:${img_tag}" "${stack_name}_check" || true
    else
        docker service update --image "${img_name}:${img_tag}" "${stack_name}_${svc_prefix}" || true
    fi

    if [ -f .env ]; then
        update_env_values ".env" "$env_key" "$img_tag"
    fi

    echo ""
    echo "✅ Update initiated. Monitor with: docker stack services $stack_name"
}

update_images_menu() {
    # update_images_menu
    # Updates Swarm service images for api/check and/or web.
    load_env
    
    echo ""
    echo "[UPDATE] Update Image Version"
    echo ""
    echo "1) API/CHECK image (${IMAGE_NAME:-}:${IMAGE_VERSION:-})"
    echo "2) WEB image (${WEB_IMAGE_NAME:-}:${WEB_IMAGE_VERSION:-})"
    echo "3) Back"
    echo ""
    read_prompt "Your choice (1-3): " img_choice

    case "$img_choice" in
        1)
            local current_tag="${IMAGE_VERSION:-latest}"
            read_prompt "Enter new API/CHECK image tag [$current_tag]: " new_tag
            _update_image_service "$IMAGE_NAME" "${new_tag:-$current_tag}" "api_check" "IMAGE_VERSION"
            ;;
        2)
            local current_tag="${WEB_IMAGE_VERSION:-latest}"
            read_prompt "Enter new WEB image tag [$current_tag]: " new_tag
            _update_image_service "$WEB_IMAGE_NAME" "${new_tag:-$current_tag}" "web" "WEB_IMAGE_VERSION"
            ;;
        *)
            return 0
            ;;
    esac
}

_scale_service_logic() {
    # _scale_service_logic
    # Performs the actual docker service scale and updates .env.
    local svc_name="$1"
    local replicas="$2"
    local env_key="$3"
    local stack_name="${STACK_NAME:-statechecker}"

    docker service scale "${stack_name}_${svc_name}=${replicas}" || true
    if [ -f .env ]; then
        update_env_values ".env" "$env_key" "$replicas"
    fi
}

scale_services_menu() {
    # scale_services_menu
    # Scales selected stack services and persists replica env vars.
    load_env
    
    echo ""
    echo "[SCALE] Scale Services"
    echo ""
    echo "1) api"
    echo "2) check"
    echo "3) web"
    echo "4) phpmyadmin"
    echo "5) Back"
    echo ""
    read_prompt "Your choice (1-5): " svc_choice

    [ "$svc_choice" = "5" ] && return 0

    read_prompt "Number of replicas: " replicas
    [ -z "$replicas" ] && { echo "❌ Replicas cannot be empty"; return 1; }

    case "$svc_choice" in
        1) _scale_service_logic "api" "$replicas" "API_REPLICAS" ;;
        2) _scale_service_logic "check" "$replicas" "CHECK_REPLICAS" ;;
        3) _scale_service_logic "web" "$replicas" "WEB_REPLICAS" ;;
        4) _scale_service_logic "phpmyadmin" "$replicas" "PHPMYADMIN_REPLICAS" ;;
        *) echo "❌ Invalid selection" ;;
    esac
}

_get_no_proxy_awk_script() {
    # Returns the awk script used for no-proxy transformation.
    cat <<'EOF'
        BEGIN {
            section=""
            current_service=""
            api_has_ports=0
            web_has_ports=0
            pma_has_ports=0
            skip_traefik_net=0
            in_labels=0
            labels_indent=0
            labels_count=0
            kept_labels_count=0
        }

        function maybe_inject_ports_before_leave() {
            if (section=="services" && current_service=="api" && api_has_ports==0) {
                print "    ports:"
                print "      - \"" api_port ":" api_port "\""
                api_has_ports=1
            }
            if (section=="services" && current_service=="web" && web_has_ports==0) {
                print "    ports:"
                print "      - \"" web_port ":80\""
                web_has_ports=1
            }
            if (section=="services" && current_service=="phpmyadmin" && pma_has_ports==0) {
                print "    ports:"
                print "      - \"" pma_port ":80\""
                pma_has_ports=1
            }
        }

        {
            line=$0

            if (in_labels==1) {
                if (match(line, /^[[:space:]]*/)) { current_indent=RLENGTH } else { current_indent=0 }
                if (current_indent <= labels_indent && line ~ /^[[:space:]]*[^[:space:]]/) {
                    if (kept_labels_count > 0) {
                        print labels_header
                        for (i=1; i<=kept_labels_count; i++) { print kept_labels[i] }
                    }
                    in_labels=0; labels_indent=0; labels_count=0; kept_labels_count=0
                } else {
                    labels_count++
                    if (line !~ /^[[:space:]]*-[[:space:]]*traefik\./) {
                        kept_labels_count++; kept_labels[kept_labels_count]=line
                    }
                    next
                }
            }

            if (skip_traefik_net==1) {
                if (line ~ /^  [^[:space:]]/) { skip_traefik_net=0 } else { next }
            }

            if (line ~ /^services:[[:space:]]*$/) {
                section="services"; current_service=""; print line; next
            }

            if (line ~ /^networks:[[:space:]]*$/) {
                maybe_inject_ports_before_leave(); section="networks"; current_service=""; print line; next
            }

            if (line ~ /^secrets:[[:space:]]*$/) {
                maybe_inject_ports_before_leave(); section="secrets"; current_service=""; print line; next
            }

            if (section=="networks" && line ~ /^  traefik:[[:space:]]*$/) {
                skip_traefik_net=1; next
            }

            if (line ~ /^[[:space:]]+-[[:space:]]+traefik[[:space:]]*$/) { next }
            if (line ~ /^[[:space:]]+-[[:space:]]+traefik\./) { next }

            if (line ~ /^[[:space:]]+labels:[[:space:]]*$/) {
                in_labels=1; labels_header=line
                if (match(line, /^[[:space:]]*/)) { labels_indent=RLENGTH } else { labels_indent=0 }
                labels_count=0; kept_labels_count=0; next
            }

            if (section=="services" && line ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/) {
                maybe_inject_ports_before_leave()
                current_service=line; sub(/^  /, "", current_service); sub(/:[[:space:]]*$/, "", current_service)
                api_has_ports=0; web_has_ports=0; pma_has_ports=0; print line; next
            }

            if (section=="services" && current_service=="api" && line ~ /^    ports:[[:space:]]*$/) { api_has_ports=1 }
            if (section=="services" && current_service=="web" && line ~ /^    ports:[[:space:]]*$/) { web_has_ports=1 }
            if (section=="services" && current_service=="phpmyadmin" && line ~ /^    ports:[[:space:]]*$/) { pma_has_ports=1 }

            if (section=="services" && current_service=="api" && api_has_ports==0 && line ~ /^    deploy:[[:space:]]*$/) {
                print "    ports:"; print "      - \"" api_port ":" api_port "\""; api_has_ports=1
            }
            if (section=="services" && current_service=="web" && web_has_ports==0 && line ~ /^    deploy:[[:space:]]*$/) {
                print "    ports:"; print "      - \"" web_port ":80\""; web_has_ports=1
            }
            if (section=="services" && current_service=="phpmyadmin" && pma_has_ports==0 && line ~ /^    deploy:[[:space:]]*$/) {
                print "    ports:"; print "      - \"" pma_port ":80\""; pma_has_ports=1
            }

            print line
        }

        END {
            if (in_labels==1 && kept_labels_count > 0) {
                print labels_header; for (i=1; i<=kept_labels_count; i++) { print kept_labels[i] }
            }
            maybe_inject_ports_before_leave()
        }
EOF
}

_apply_no_proxy_transformations() {
    # _apply_no_proxy_transformations
    # Modifies a rendered stack file for "no proxy" deployments.
    local stack_file="$1"
    [ -z "$stack_file" ] || [ ! -f "$stack_file" ] && { echo "❌ Stack file missing"; return 1; }

    local api_port="${API_PORT:-8787}"
    local web_port="${WEB_PORT:-8080}"
    local pma_port="${PHPMYADMIN_PORT:-8081}"
    local tmp_file="${stack_file}.tmp"

    awk -v api_port="$api_port" -v web_port="$web_port" -v pma_port="$pma_port" "$(_get_no_proxy_awk_script)" "$stack_file" > "$tmp_file"
    mv "$tmp_file" "$stack_file"
    return 0
}

load_env() {
    # load_env
    # Loads environment variables from .env into the current shell.
    # Returns:
    # - 0 if .env exists and was loaded
    # - 1 if .env does not exist
    if [ -f .env ]; then
        _sanitize_env_file_statechecker_config || true
        local env_lines
        env_lines=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' .env 2>/dev/null | grep -v '^STATECHECKER_SERVER_CONFIG=' | sed 's/\r$//' || true)
        if [ -n "$env_lines" ]; then
            set -a
            source <(printf '%s\n' "$env_lines")
            set +a
        fi
        return 0
    else
        return 1
    fi
}

update_env_values() {
    # update_env_values
    # Updates (or inserts) a KEY=VALUE pair in a dotenv file.
    #
    # Arguments:
    # - $1: env file path
    # - $2: key
    # - $3: value
    local env_file="$1"
    local key="$2"
    local value="$3"

    if [ -z "$env_file" ] || [ -z "$key" ]; then
        return 1
    fi

    value="${value//$'\r'/}"
    value="${value//$'\n'/}"

    local quoted_value
    quoted_value="$value"
    quoted_value="${quoted_value//\\/\\\\}"
    quoted_value="${quoted_value//\"/\\\"}"
    quoted_value="${quoted_value//\$/\\$}"
    quoted_value="${quoted_value//\`/\\\`}" 
    quoted_value="\"${quoted_value}\""

    local line_replacement
    line_replacement="${key}=${quoted_value}"

    local sed_replacement
    sed_replacement=$(printf '%s' "$line_replacement" | sed 's/[\\&|]/\\\\&/g')

    if [ "$key" = "STATECHECKER_SERVER_CONFIG" ] && [ -f "$env_file" ] && grep -q "^${key}=" "$env_file" 2>/dev/null; then
        local repl_file tmp_file
        repl_file="${env_file}.repl.$$"
        tmp_file="${env_file}.tmp.$$"
        printf '%s\n' "$line_replacement" > "$repl_file"
        awk -v key="$key" -v repl_file="$repl_file" '
            BEGIN { skip=0 }
            {
                if (skip == 1) {
                    if ($0 ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { skip=0; print $0 }
                    next
                }
                if ($0 ~ ("^" key "=")) {
                    while ((getline r < repl_file) > 0) { print r }
                    close(repl_file)
                    skip=1
                    next
                }
                print $0
            }
        ' "$env_file" > "$tmp_file"
        mv "$tmp_file" "$env_file"
        rm -f "$repl_file" 2>/dev/null || true
        return 0
    fi

    if [ ! -f "$env_file" ]; then
        printf '%s\n' "$line_replacement" >> "$env_file"
        return 0
    fi

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s|^${key}=.*|${sed_replacement}|" "$env_file"
        else
            sed -i "s|^${key}=.*|${sed_replacement}|" "$env_file"
        fi
    else
        printf '%s\n' "$line_replacement" >> "$env_file"
    fi
}

source "$(dirname "${BASH_SOURCE[0]}")/data-dirs.sh"

_ensure_data_dirs_before_deploy() {
    # _ensure_data_dirs_before_deploy
    # Reads DATA_ROOT from .env and ensures directories are prepared before deployment.
    if [ ! -f .env ]; then
        return 0
    fi

    local data_root
    data_root=$(grep '^DATA_ROOT=' .env 2>/dev/null | head -n 1 | cut -d'=' -f2- | tr -d ' "' | tr -d '\r')
    
    if [ -z "$data_root" ]; then
        return 0
    fi

    local project_root
    project_root="$(pwd)"

    if ! prepare_data_root "$data_root" "$project_root"; then
        echo "❌ [ERROR] Failed to prepare data directories. Aborting deployment."
        return 1
    fi
    return 0
}

_get_compose_command() {
    # _get_compose_command
    # Detects available docker-compose command.
    if command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    elif docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    else
        echo ""
    fi
}

_render_stack_config() {
    # _render_stack_config
    # Renders config-stack.yml using docker compose config.
    local compose_cmd=($1)
    local env_file="$2"
    local output_file="$3"

    local compose_env_opt=()
    if [ -f "$env_file" ] && "${compose_cmd[@]}" --help 2>/dev/null | grep -q -- '--env-file'; then
        compose_env_opt=(--env-file "$env_file")
    fi

    "${compose_cmd[@]}" -f config-stack.yml "${compose_env_opt[@]}" config > "$output_file"
}

deploy_stack() {
    # deploy_stack
    # Deploys the Docker Swarm stack using config-stack.yml.
    local stack_name="${STACK_NAME:-statechecker}"
    echo "🚀 Deploying stack: $stack_name"
    echo ""
    
    [ -f .env ] || { echo "❌ .env file not found. Please create it first."; return 1; }
    load_env

    if [ "${TELEGRAM_ENABLED:-false}" != "true" ] && ! check_secret_exists "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN"; then
        echo "[INFO] TELEGRAM_ENABLED=false and secret missing; creating placeholder secret STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN"
        printf '%s' 'DISABLED' | docker secret create "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN" - >/dev/null 2>&1 || true
    fi

    if [ "${EMAIL_ENABLED:-false}" != "true" ] && ! check_secret_exists "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD"; then
        echo "[INFO] EMAIL_ENABLED=false and secret missing; creating placeholder secret STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD"
        printf '%s' 'DISABLED' | docker secret create "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD" - >/dev/null 2>&1 || true
    fi

    if ! check_secret_exists "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON"; then
        echo "[INFO] Google Drive secret missing; creating placeholder secret STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON"
        printf '%s' '{}' | docker secret create "STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON" - >/dev/null 2>&1 || true
    fi

    local cmd_str
    cmd_str=$(_get_compose_command)
    if [ -z "$cmd_str" ]; then
        echo "⚠️  Neither docker-compose nor 'docker compose' is available. Deploying raw stack file."
        docker stack deploy -c config-stack.yml "$stack_name"
        return $?
    fi

    local temp_config=".stack-deploy-temp.yml"
    if ! _render_stack_config "$cmd_str" ".env" "$temp_config"; then
        echo "❌ Failed to render config-stack.yml via docker compose"
        rm -f "$temp_config" 2>/dev/null || true
        return 1
    fi

    if [ "${PROXY_TYPE:-traefik}" = "none" ]; then
        echo "[INFO] PROXY_TYPE=none: deploying without Traefik (direct ports)"
        _apply_no_proxy_transformations "$temp_config" || { rm -f "$temp_config" 2>/dev/null || true; return 1; }
    fi

    docker stack deploy -c "$temp_config" "$stack_name"
    local deploy_rc=$?
    rm -f "$temp_config" 2>/dev/null || true
    
    [ $deploy_rc -eq 0 ] && { echo ""; echo "✅ Stack deployed: $stack_name"; echo ""; echo "📋 Stack services:"; docker stack services "$stack_name"; } || echo "❌ Failed to deploy stack"
}

# Helper: Wait for stack and its networks to be fully removed
# Usage: _wait_for_stack_removal <stack_name> [timeout_seconds]
_wait_for_stack_removal() {
    local stack_name="$1"
    local timeout="${2:-120}"
    local elapsed=0
    local interval=2
    
    echo ""
    echo "⏳ Waiting for stack '$stack_name' to be fully removed..."
    
    while [ $elapsed -lt $timeout ]; do
        # Check if stack still exists
        local stack_exists=false
        if docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx "$stack_name"; then
            stack_exists=true
        fi
        
        # Check if any networks with stack prefix still exist
        local networks_exist=false
        if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${stack_name}_"; then
            networks_exist=true
        fi
        
        # If both stack and networks are gone, we're done
        if [ "$stack_exists" = false ] && [ "$networks_exist" = false ]; then
            echo "✅ Stack '$stack_name' and all its networks have been fully removed."
            return 0
        fi
        
        # Show progress
        if [ "$stack_exists" = true ]; then
            printf "\r   Stack services still removing... (%ds elapsed)" "$elapsed"
        elif [ "$networks_exist" = true ]; then
            printf "\r   Networks still removing... (%ds elapsed)       " "$elapsed"
        fi
        
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    echo ""
    echo "⚠️  Timeout reached. Stack may not be fully removed yet."
    echo "   Please check manually with: docker stack ls && docker network ls | grep ${stack_name}"
    return 1
}

remove_stack() {
    # remove_stack
    # Removes the Docker Swarm stack.
    load_env
    local stack_name="${STACK_NAME:-statechecker}"
    
    echo "🛑 Removing stack: $stack_name"
    docker stack rm "$stack_name"
    
    if [ $? -eq 0 ]; then
        _wait_for_stack_removal "$stack_name"
    else
        echo "❌ Failed to remove stack"
    fi
}

show_stack_status() {
    # show_stack_status
    # Displays docker stack services for the current stack.
    load_env
    local stack_name="${STACK_NAME:-statechecker}"
    
    echo "📋 Stack status: $stack_name"
    echo ""
    docker stack services "$stack_name" 2>/dev/null || echo "Stack not found or not running"
}

show_stack_logs() {
    # show_stack_logs
    # Interactive selection of which service logs to follow.
    load_env
    local stack_name="${STACK_NAME:-statechecker}"
    
    echo "Which service logs do you want to view?"
    echo "1) api"
    echo "2) check"
    echo "3) web"
    echo "4) db"
    echo "5) All services"
    echo ""
    
    read_prompt "Select (1-5): " log_choice
    
    case $log_choice in
        1)
            docker service logs "${stack_name}_api" -f
            ;;
        2)
            docker service logs "${stack_name}_check" -f
            ;;
        3)
            docker service logs "${stack_name}_web" -f
            ;;
        4)
            docker service logs "${stack_name}_db" -f
            ;;
        5)
            local services
            services=$(docker service ls --filter "label=com.docker.stack.namespace=${stack_name}" --format '{{.Name}}' 2>/dev/null)
            if [ -z "$services" ]; then
                echo "Stack not found or no services running"
            else
                local svc
                for svc in $services; do
                    echo ""
                    echo "===== $svc ====="
                    docker service logs --tail 50 "$svc" 2>/dev/null || true
                done
            fi
            ;;
        *)
            echo "❌ Invalid selection"
            ;;
    esac
}

_print_pma_enabled_msg() {
    # _print_pma_enabled_msg
    # Prints success message with endpoint based on proxy type.
    if [ "${PROXY_TYPE:-traefik}" = "none" ]; then
        echo "phpMyAdmin is now ENABLED. Access it via http://localhost:${PHPMYADMIN_PORT:-8081}"
    else
        local url
        url=$(grep '^PHPMYADMIN_URL=' .env 2>/dev/null | cut -d'=' -f2- | tr -d ' "')
        [ -n "$url" ] && echo "phpMyAdmin is now ENABLED. Access it via https://$url" || echo "phpMyAdmin is now ENABLED."
    fi
}

toggle_phpmyadmin() {
    # toggle_phpmyadmin
    # Toggles the phpMyAdmin service replica count between 0 and 1 and persists
    # PHPMYADMIN_REPLICAS in .env.
    load_env
    local stack_name="${STACK_NAME:-statechecker}"
    local svc_name="${stack_name}_phpmyadmin"

    echo "🔁 Toggle phpMyAdmin service for stack: $stack_name"
    echo ""

    if ! docker service inspect "$svc_name" >/dev/null 2>&1; then
        echo "phpMyAdmin service not found. Make sure the stack is deployed."
        return
    fi

    local current_replicas
    current_replicas=$(docker service inspect --format '{{.Spec.Mode.Replicated.Replicas}}' "$svc_name" 2>/dev/null || echo "0")
    local new_replicas=$([ "$current_replicas" -eq 0 ] && echo 1 || echo 0)

    echo "Scaling $svc_name from $current_replicas to $new_replicas replicas..."
    docker service scale "${svc_name}=$new_replicas"

    [ -f .env ] && update_env_values ".env" "PHPMYADMIN_REPLICAS" "$new_replicas"

    if [ "$new_replicas" -eq 0 ]; then
        echo "phpMyAdmin is now DISABLED."
    else
        _print_pma_enabled_msg
    fi
}

create_required_secrets_menu() {
    # create_required_secrets_menu
    # Interactive creator for required Docker secrets.
    echo ""
    echo "🔐 Create required secrets"
    echo ""

    local prompt_auth="Create"
    check_secret_exists "STATECHECKER_SERVER_AUTHENTICATION_TOKEN" && prompt_auth="Recreate"
    read_prompt "$prompt_auth STATECHECKER_SERVER_AUTHENTICATION_TOKEN? (y/N): " create_auth
    if [[ "$create_auth" =~ ^[Yy]$ ]]; then
        create_secret_interactive "STATECHECKER_SERVER_AUTHENTICATION_TOKEN" "API authentication token" || true
    fi

    local prompt_root="Create"
    check_secret_exists "STATECHECKER_SERVER_DB_ROOT_USER_PW" && prompt_root="Recreate"
    read_prompt "$prompt_root STATECHECKER_SERVER_DB_ROOT_USER_PW? (y/N): " create_root
    if [[ "$create_root" =~ ^[Yy]$ ]]; then
        create_secret_interactive "STATECHECKER_SERVER_DB_ROOT_USER_PW" "MySQL root password" || true
    fi

    local prompt_user="Create"
    check_secret_exists "STATECHECKER_SERVER_DB_USER_PW" && prompt_user="Recreate"
    read_prompt "$prompt_user STATECHECKER_SERVER_DB_USER_PW? (y/N): " create_user
    if [[ "$create_user" =~ ^[Yy]$ ]]; then
        create_secret_interactive "STATECHECKER_SERVER_DB_USER_PW" "MySQL user password" || true
    fi
}

create_optional_secrets_menu() {
    # create_optional_secrets_menu
    # Interactive creator for optional Docker secrets.
    echo ""
    echo "🔐 Create optional secrets"
    echo ""

    load_env || true

    if [ "${TELEGRAM_ENABLED:-false}" = "true" ]; then
        read_prompt "Create Telegram bot token secret? (y/N): " create_telegram
        if [[ "$create_telegram" =~ ^[Yy]$ ]]; then
            create_secret_interactive "STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN" "Telegram bot token" || true
        fi
    else
        echo "[INFO] TELEGRAM_ENABLED=false: skipping Telegram secret prompt"
    fi

    if [ "${EMAIL_ENABLED:-false}" = "true" ]; then
        read_prompt "Create Email password secret? (y/N): " create_email
        if [[ "$create_email" =~ ^[Yy]$ ]]; then
            create_secret_interactive "STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD" "Email SMTP password" || true
        fi
    else
        echo "[INFO] EMAIL_ENABLED=false: skipping Email secret prompt"
    fi
    
    read_prompt "Create Google Drive service account secret? (y/N): " create_gdrive
    if [[ "$create_gdrive" =~ ^[Yy]$ ]]; then
        _create_google_drive_secret || true
    fi
}

_create_google_drive_secret() {
    # _create_google_drive_secret
    # Creates the Google Drive service account JSON secret from a file.
    # Offers to create the file if it doesn't exist (user pastes JSON into editor).
    local secret_name="STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON"
    local default_json_path="./service_account_key.json"
    
    echo ""
    echo "📁 Google Drive Service Account JSON Secret"
    echo "============================================"
    echo ""
    echo "Options:"
    echo "1) Provide path to existing service_account_key.json file"
    echo "2) Create new file and paste JSON content (recommended)"
    echo "3) Skip"
    echo ""
    read_prompt "Your choice (1-3) [2]: " gdrive_choice
    gdrive_choice="${gdrive_choice:-2}"
    
    case "$gdrive_choice" in
        1)
            read_prompt "Path to service account JSON file: " json_path
            if [ -f "$json_path" ]; then
                create_secret_from_file "$secret_name" "$json_path" || return 1
                echo ""
                read_prompt "Delete the JSON file now? (recommended for security) (Y/n): " delete_json
                if [[ ! "$delete_json" =~ ^[Nn]$ ]]; then
                    rm -f "$json_path" 2>/dev/null && echo "✅ Deleted $json_path"
                fi
            else
                echo "❌ File not found: $json_path"
                return 1
            fi
            ;;
        2)
            echo ""
            echo "Creating $default_json_path for you to paste your JSON content."
            echo ""
            echo "Instructions:"
            echo "  1. The editor will open with an empty file"
            echo "  2. Paste your complete Google service account JSON"
            echo "  3. Save and close the editor"
            echo ""
            
            # Create empty file
            : > "$default_json_path"
            
            # Open in editor
            if [ -z "${WIZARD_EDITOR:-}" ]; then
                wizard_choose_editor || true
            fi
            if [ -n "${WIZARD_EDITOR:-}" ]; then
                wizard_edit_file "$default_json_path" "$WIZARD_EDITOR"
            else
                echo "No editor configured. Please paste JSON into $default_json_path manually."
                read_prompt "Press Enter when done..."
            fi
            
            # Validate JSON is not empty
            if [ ! -s "$default_json_path" ]; then
                echo "❌ File is empty. Secret not created."
                rm -f "$default_json_path" 2>/dev/null
                return 1
            fi
            
            # Create secret from file
            create_secret_from_file "$secret_name" "$default_json_path" || { rm -f "$default_json_path" 2>/dev/null; return 1; }
            
            # Always delete the JSON file after creating secret
            rm -f "$default_json_path" 2>/dev/null
            echo "✅ Deleted $default_json_path (secret is now stored securely in Docker)"
            ;;
        3|*)
            echo "[SKIP] Google Drive secret not created"
            return 0
            ;;
    esac
    
    return 0
}

_print_main_menu_text() {
    # _print_main_menu_text
    # Prints the main menu options.
    local menu_exit="$1"
    echo ""
    echo "================ Main Menu ================"
    echo ""
    echo "Deployment:"
    echo "  1) Deploy stack"
    echo "  2) Remove stack"
    echo "  3) Show stack status"
    echo "  4) Health check"
    echo "  5) View service logs"
    echo ""
    echo "Management:"
    echo "  6) Update image version"
    echo "  7) Scale services"
    echo "  8) Toggle phpMyAdmin (enable/disable)"
    echo ""
    echo "Setup:"
    echo "  9) Re-run setup wizard"
    echo ""
    echo "Extras:"
    echo "Secrets:"
    echo "  10) Check required secrets"
    echo "  11) Create required secrets"
    echo "  12) Create secrets from secrets.env file"
    echo "  13) Create optional secrets (Telegram, Email, Google Drive)"
    echo "  14) List all secrets"
    echo ""
    echo "CI/CD:"
    echo "  15) GitHub Actions CI/CD helper"
    echo ""
    echo "  ${menu_exit}) Exit"
    echo ""
}

_handle_main_menu_choice() {
    # _handle_main_menu_choice
    # Dispatches menu choices to appropriate functions.
    local choice="$1"
    local menu_exit="$2"
    local compose_file="$3"

    case $choice in
        1)
            echo "[DEPLOY] Deploying stack..."
            echo ""
            if ! _ensure_data_dirs_before_deploy; then return; fi
            echo "[WARN] Make sure you have:"
            echo "   - Created Docker secrets"
            if [ "${PROXY_TYPE:-traefik}" = "traefik" ]; then
                echo "   - Configured your domain DNS (Traefik mode)"
                echo "   - Set API_URL / PHPMYADMIN_URL / WEB_URL to real hostnames"
            else
                echo "   - Set WEB_PORT / PHPMYADMIN_PORT for localhost access (no-proxy mode)"
            fi
            echo ""
            deploy_stack
            ;;
        2) remove_stack ;;
        3) show_stack_status ;;
        4) check_stack_health ;;
        5) show_stack_logs ;;
        6) update_images_menu ;;
        7) scale_services_menu ;;
        8) toggle_phpmyadmin ;;
        9)
            if [ -f "./setup/setup-wizard.sh" ]; then
                bash "./setup/setup-wizard.sh"
            else
                echo "❌ Setup wizard not found at ./setup/setup-wizard.sh"
            fi
            ;;
        10) check_required_secrets; check_optional_secrets ;;
        11) create_required_secrets_menu ;;
        12) create_secrets_from_env_file "secrets.env" "setup/secrets.env.template" ;;
        13) create_optional_secrets_menu ;;
        14) list_secrets ;;
        15) run_ci_cd_github_helper ;;
        ${menu_exit}) echo "👋 Goodbye!"; exit 0 ;;
        *) echo "❌ Invalid selection" ;;
    esac
}

show_main_menu() {
     # show_main_menu
     # Main interactive menu loop.
     local choice
     local MENU_EXIT=16
     
     while true; do
        _print_main_menu_text "$MENU_EXIT"
        read_prompt "Your choice (1-${MENU_EXIT}): " choice
        _handle_main_menu_choice "$choice" "$MENU_EXIT" "$1"
     done
 }
