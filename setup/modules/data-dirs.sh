#!/bin/bash
#
# data-dirs.sh
# Module for preparing data directories and install files for Swarm Statechecker
#

prepare_data_root() {
    # prepare_data_root
    # Creates all required directories under DATA_ROOT and copies required install
    # files (DB schema and migrations) into place.
    #
    # Arguments:
    # - $1: DATA_ROOT directory
    # - $2: PROJECT_ROOT directory
    #
    # Returns:
    # - 0 if successful
    # - 1 otherwise
    local data_root="$1"
    local project_root="$2"

    local normalized_data_root normalized_project_root
    normalized_data_root="${data_root%/}"
    normalized_project_root="${project_root%/}"

    if [ -z "$data_root" ]; then
        echo "❌ DATA_ROOT cannot be empty"
        return 1
    fi

    echo ""
    echo "[DATA] Preparing DATA_ROOT: $data_root"

    local schema_src schema_dest
    schema_src="$normalized_project_root/install/database/state_checker.sql"
    schema_dest="$normalized_data_root/install/database/state_checker.sql"

    local same_as_project_root=false
    if [ "$normalized_data_root" = "$normalized_project_root" ] || [ "$schema_src" = "$schema_dest" ]; then
        same_as_project_root=true
    fi

    # Parity with swarm-ananda: delete existing init files but keep db_data
    if [ "$same_as_project_root" = false ] && [ -f "$schema_dest" ]; then
        echo "[INFO] Removing old database init file..."
        rm -f "$schema_dest"
    fi

    mkdir -p "$data_root/logs/api" "$data_root/logs/check" "$data_root/db_data" "$data_root/install/database/migrations"

    if [ ! -f "$schema_src" ]; then
        echo "❌ Missing schema file: $schema_src"
        return 1
    fi

    if [ "$same_as_project_root" = true ]; then
        echo "[INFO] DATA_ROOT equals project root; skipping install file copy to avoid overwriting repository files."
    else
        cp "$schema_src" "$schema_dest"

        if [ -d "$normalized_project_root/install/database/migrations" ]; then
            # Clean old migrations first
            rm -rf "$data_root/install/database/migrations/"* 2>/dev/null || true
            cp -R "$normalized_project_root/install/database/migrations/"* "$data_root/install/database/migrations/" 2>/dev/null || true
            if [ -f "$data_root/install/database/migrations/run_migrations.sh" ]; then
                chmod +x "$data_root/install/database/migrations/run_migrations.sh" 2>/dev/null || true
            fi
        fi
    fi

    echo "✅ DATA_ROOT prepared"
    return 0
}
