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

    if [ -z "$data_root" ]; then
        echo "❌ DATA_ROOT cannot be empty"
        return 1
    fi

    echo ""
    echo "[DATA] Preparing DATA_ROOT: $data_root"

    mkdir -p "$data_root/logs/api" "$data_root/logs/check" "$data_root/db_data" "$data_root/install/database/migrations"

    if [ ! -f "$project_root/install/database/state_checker.sql" ]; then
        echo "❌ Missing schema file: $project_root/install/database/state_checker.sql"
        return 1
    fi

    cp "$project_root/install/database/state_checker.sql" "$data_root/install/database/state_checker.sql"

    if [ -d "$project_root/install/database/migrations" ]; then
        cp -R "$project_root/install/database/migrations/"* "$data_root/install/database/migrations/" 2>/dev/null || true
        if [ -f "$data_root/install/database/migrations/run_migrations.sh" ]; then
            chmod +x "$data_root/install/database/migrations/run_migrations.sh" 2>/dev/null || true
        fi
    fi

    echo "✅ DATA_ROOT prepared"
    return 0
}
