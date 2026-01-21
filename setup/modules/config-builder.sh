#!/bin/bash
# ==============================================================================
# config-builder.sh - Configuration file builder module
# ==============================================================================
# This module assembles .env and swarm-stack.yml from modular templates.
# ==============================================================================

# ------------------------------------------------------------------------------
# Build .env file from templates
#
# Arguments:
#   $1 = proxy_type   → "traefik" or "none"
#   $2 = project_root → Root directory of the project
#
# Returns:
#   None (creates .env file)
# ------------------------------------------------------------------------------
build_env_file() {
    local proxy_type="$1"
    local project_root="$2"
    
    echo "[BUILD] Building .env file..."
    
    # Start with base template
    cat "${project_root}/setup/env-templates/.env.base.template" > "${project_root}/.env"
    
    # Add proxy configuration
    if [ "$proxy_type" = "traefik" ]; then
        cat "${project_root}/setup/env-templates/.env.proxy-traefik.template" >> "${project_root}/.env"
    else
        cat "${project_root}/setup/env-templates/.env.proxy-none.template" >> "${project_root}/.env"
    fi
    
    echo "[OK] .env file created"
}

# ------------------------------------------------------------------------------
# Build swarm-stack.yml from modular templates
#
# Arguments:
#   $1 = proxy_type   → "traefik" or "none"
#   $2 = project_root → Root directory of the project
#   $3 = ssl_mode     → "direct" or "proxy" (default: direct)
#   $4 = include_pma  → "true" or "false" (default: true)
#   $5 = include_web  → "true" or "false" (default: true)
#
# Returns:
#   None (creates swarm-stack.yml)
# ------------------------------------------------------------------------------
build_stack_file() {
    local proxy_type="$1"
    local project_root="$2"
    local ssl_mode="${3:-direct}"
    local include_pma="${4:-true}"
    local include_web="${5:-true}"
    
    echo "[BUILD] Building swarm-stack.yml..."
    
    local modules_dir="${project_root}/setup/compose-modules"
    local snippets_dir="${modules_dir}/snippets"
    local stack_file="${project_root}/swarm-stack.yml"
    
    # Start with base
    cat "${modules_dir}/base.yml" > "$stack_file"
    
    # Build API service from template with snippet injection
    local temp_api="${modules_dir}/api.temp.yml"
    cp "${modules_dir}/api.template.yml" "$temp_api"
    
    # Inject proxy network snippet (only for Traefik)
    if [ "$proxy_type" = "traefik" ]; then
        local proxy_network_snippet="${snippets_dir}/proxy-traefik.network.yml"
        if [ -f "$proxy_network_snippet" ]; then
            _inject_snippet "$temp_api" "###PROXY_NETWORK###" "$proxy_network_snippet"
        fi
    fi
    _remove_placeholder "$temp_api" "###PROXY_NETWORK###"
    
    # Inject proxy labels/ports for API
    if [ "$proxy_type" = "traefik" ]; then
        local proxy_labels_snippet="${snippets_dir}/proxy-traefik-${ssl_mode}-ssl.labels.yml"
        if [ -f "$proxy_labels_snippet" ]; then
            _inject_snippet "$temp_api" "###PROXY_LABELS###" "$proxy_labels_snippet"
        fi
        _remove_placeholder "$temp_api" "###PROXY_LABELS###"
        _remove_placeholder "$temp_api" "###PROXY_PORTS###"
    else
        local proxy_ports_snippet="${snippets_dir}/proxy-none.ports.yml"
        if [ -f "$proxy_ports_snippet" ]; then
            _inject_snippet "$temp_api" "###PROXY_PORTS###" "$proxy_ports_snippet"
        fi
        _remove_placeholder "$temp_api" "###PROXY_PORTS###"
        _remove_placeholder "$temp_api" "###PROXY_LABELS###"
    fi
    
    cat "$temp_api" >> "$stack_file"
    rm -f "$temp_api"
    
    # Add check service (no proxy needed - internal only)
    cat "${modules_dir}/check.template.yml" >> "$stack_file"
    
    # Add database service
    cat "${modules_dir}/db.template.yml" >> "$stack_file"
    
    # Add database migration service
    cat "${modules_dir}/db-migration.template.yml" >> "$stack_file"
    
    # Add phpMyAdmin if enabled
    if [ "$include_pma" = "true" ]; then
        local temp_pma="${modules_dir}/phpmyadmin.temp.yml"
        cp "${modules_dir}/phpmyadmin.template.yml" "$temp_pma"
        
        # Inject proxy network for phpMyAdmin
        if [ "$proxy_type" = "traefik" ]; then
            local proxy_network_snippet="${snippets_dir}/proxy-traefik.network.yml"
            if [ -f "$proxy_network_snippet" ]; then
                _inject_snippet "$temp_pma" "###PROXY_NETWORK_PMA###" "$proxy_network_snippet"
            fi
        fi
        _remove_placeholder "$temp_pma" "###PROXY_NETWORK_PMA###"
        
        # Inject proxy labels/ports for phpMyAdmin
        if [ "$proxy_type" = "traefik" ]; then
            local pma_labels_snippet="${snippets_dir}/proxy-traefik-${ssl_mode}-ssl-pma.labels.yml"
            if [ -f "$pma_labels_snippet" ]; then
                _inject_snippet "$temp_pma" "###PROXY_LABELS_PMA###" "$pma_labels_snippet"
            fi
            _remove_placeholder "$temp_pma" "###PROXY_LABELS_PMA###"
            _remove_placeholder "$temp_pma" "###PROXY_PORTS_PMA###"
        else
            local pma_ports_snippet="${snippets_dir}/proxy-none-pma.ports.yml"
            if [ -f "$pma_ports_snippet" ]; then
                _inject_snippet "$temp_pma" "###PROXY_PORTS_PMA###" "$pma_ports_snippet"
            fi
            _remove_placeholder "$temp_pma" "###PROXY_PORTS_PMA###"
            _remove_placeholder "$temp_pma" "###PROXY_LABELS_PMA###"
        fi
        
        cat "$temp_pma" >> "$stack_file"
        rm -f "$temp_pma"
    fi
    
    # Add web service if enabled
    if [ "$include_web" = "true" ]; then
        local temp_web="${modules_dir}/web.temp.yml"
        cp "${modules_dir}/web.template.yml" "$temp_web"
        
        # Inject proxy network for web
        if [ "$proxy_type" = "traefik" ]; then
            local proxy_network_snippet="${snippets_dir}/proxy-traefik.network.yml"
            if [ -f "$proxy_network_snippet" ]; then
                _inject_snippet "$temp_web" "###PROXY_NETWORK_WEB###" "$proxy_network_snippet"
            fi
        fi
        _remove_placeholder "$temp_web" "###PROXY_NETWORK_WEB###"
        
        # Inject proxy labels/ports for web
        if [ "$proxy_type" = "traefik" ]; then
            local web_labels_snippet="${snippets_dir}/proxy-traefik-${ssl_mode}-ssl-web.labels.yml"
            if [ -f "$web_labels_snippet" ]; then
                _inject_snippet "$temp_web" "###PROXY_LABELS_WEB###" "$web_labels_snippet"
            fi
            _remove_placeholder "$temp_web" "###PROXY_LABELS_WEB###"
            _remove_placeholder "$temp_web" "###PROXY_PORTS_WEB###"
        else
            local web_ports_snippet="${snippets_dir}/proxy-none-web.ports.yml"
            if [ -f "$web_ports_snippet" ]; then
                _inject_snippet "$temp_web" "###PROXY_PORTS_WEB###" "$web_ports_snippet"
            fi
            _remove_placeholder "$temp_web" "###PROXY_PORTS_WEB###"
            _remove_placeholder "$temp_web" "###PROXY_LABELS_WEB###"
        fi
        
        cat "$temp_web" >> "$stack_file"
        rm -f "$temp_web"
    fi
    
    # Add footer
    cat "${modules_dir}/footer.yml" >> "$stack_file"
    
    # Add Traefik network to footer if using Traefik
    if [ "$proxy_type" = "traefik" ]; then
        local traefik_network_snippet="${snippets_dir}/traefik-network.footer.yml"
        if [ -f "$traefik_network_snippet" ]; then
            _inject_snippet "$stack_file" "###TRAEFIK_NETWORK###" "$traefik_network_snippet"
        fi
    fi
    _remove_placeholder "$stack_file" "###TRAEFIK_NETWORK###"
    
    echo "[OK] swarm-stack.yml created"
}

# ------------------------------------------------------------------------------
# Update Traefik network name placeholder in swarm-stack.yml
#
# Arguments:
#   $1 = stack_file      → Path to swarm-stack.yml
#   $2 = traefik_network → Name of the Traefik external network
#
# Returns:
#   None
# ------------------------------------------------------------------------------
update_stack_network() {
    local stack_file="$1"
    local traefik_network="$2"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|XXX_CHANGE_ME_TRAEFIK_NETWORK_NAME_XXX|$traefik_network|g" "$stack_file"
    else
        sed -i "s|XXX_CHANGE_ME_TRAEFIK_NETWORK_NAME_XXX|$traefik_network|g" "$stack_file"
    fi
}

# ------------------------------------------------------------------------------
# Update backup network integration in stack file
#
# Arguments:
#   $1 = stack_file            → Path to swarm-stack.yml
#   $2 = enable_backup_network → "true" or "false" (default: false)
#
# Returns:
#   0 on success, 1 otherwise
# ------------------------------------------------------------------------------
update_stack_backup_network() {
    local stack_file="$1"
    local enable_backup_network="${2:-false}"

    if [ ! -f "$stack_file" ]; then
        echo "[ERROR] Stack file not found: $stack_file"
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)

    awk -v enable="$enable_backup_network" '
        BEGIN {
            in_db=0;
            in_networks=0;
            skipping_backup_def=0;
            added_backup_def=0;
            added_db=0;
        }

        /^  db:$/ { in_db=1 }
        in_db && /^  [A-Za-z0-9_]+:$/ && $0 !~ /^  db:$/ { in_db=0 }

        /^networks:$/ { in_networks=1 }
        in_networks && /^secrets:$/ { in_networks=0 }

        # Drop existing backup network definition (we may re-add if enabled)
        in_networks && /^  backup:$/ { skipping_backup_def=1; next }
        skipping_backup_def {
            if ($0 ~ /^  [A-Za-z0-9_]+:$/ || $0 ~ /^secrets:$/) {
                skipping_backup_def=0
            } else {
                next
            }
        }

        # Drop existing DB attachment line
        in_db && /^      - backup$/ { next }

        { print }

        # Add external backup network definition
        in_networks && enable=="true" && /^    driver: overlay$/ && !added_backup_def {
            print "  backup:";
            print "    external: true";
            print "    name: backup-net";
            added_backup_def=1
        }

        # Attach DB service to backup network (only if local DB service exists)
        in_db && enable=="true" && /^      - backend$/ && !added_db {
            print "      - backup";
            added_db=1
        }
    ' "$stack_file" > "$tmp_file" && mv "$tmp_file" "$stack_file"

    return 0
}

# ------------------------------------------------------------------------------
# Helper: Inject snippet file contents after a placeholder line
#
# Arguments:
#   $1 = target_file  → File to modify
#   $2 = placeholder  → Placeholder string to find
#   $3 = snippet_file → File containing content to inject
#
# Returns:
#   None
# ------------------------------------------------------------------------------
_inject_snippet() {
    local target_file="$1"
    local placeholder="$2"
    local snippet_file="$3"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' -e "/${placeholder}/r ${snippet_file}" "$target_file"
    else
        sed -i "/${placeholder}/r ${snippet_file}" "$target_file"
    fi
}

# ------------------------------------------------------------------------------
# Helper: Remove placeholder line from file
#
# Arguments:
#   $1 = target_file → File to modify
#   $2 = placeholder → Placeholder string to remove
#
# Returns:
#   None
# ------------------------------------------------------------------------------
_remove_placeholder() {
    local target_file="$1"
    local placeholder="$2"
    
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "/${placeholder}/d" "$target_file"
    else
        sed -i "/${placeholder}/d" "$target_file"
    fi
}

# ------------------------------------------------------------------------------
# Create timestamped backups of .env and swarm-stack.yml
#
# Arguments:
#   $1 = project_root → Root directory of the project
#
# Returns:
#   None
# ------------------------------------------------------------------------------
backup_existing_files() {
    local project_root="$1"
    local timestamp=$(date +%Y_%m_%d__%H_%M_%S)
    
    mkdir -p "${project_root}/backup/env"
    mkdir -p "${project_root}/backup/swarm-stack-yml"
    
    if [ -f "${project_root}/.env" ]; then
        local backup_file="${project_root}/backup/env/.env.${timestamp}"
        cp "${project_root}/.env" "$backup_file"
        echo "[BACKUP] Backed up .env to backup/env/.env.${timestamp}"
    fi
    
    if [ -f "${project_root}/swarm-stack.yml" ]; then
        local backup_file="${project_root}/backup/swarm-stack-yml/swarm-stack.yml.${timestamp}"
        cp "${project_root}/swarm-stack.yml" "$backup_file"
        echo "[BACKUP] Backed up swarm-stack.yml to backup/swarm-stack-yml/swarm-stack.yml.${timestamp}"
    fi
}

