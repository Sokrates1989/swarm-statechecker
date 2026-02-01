#!/bin/bash

# menu_keycloak.sh
# Keycloak-related menu handlers for Statechecker.
# Provides functions for bootstrapping Keycloak realms and managing authentication.

# Source utility functions
MENU_KEYCLOAK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${MENU_KEYCLOAK_DIR}/wizard.sh" ]; then
    # shellcheck source=/dev/null
    source "${MENU_KEYCLOAK_DIR}/wizard.sh"
fi

# Available roles for statechecker
STATECHECKER_ROLES=(
    "statechecker:admin"
    "statechecker:read"
)

# _update_env_with_keycloak_config
# Updates the .env file with Keycloak configuration values.
# Args: $1=project_root, $2=keycloak_url, $3=realm, $4=frontend_client, $5=backend_client
_update_env_with_keycloak_config() {
    local project_root="$1"
    local keycloak_url="$2"
    local realm="$3"
    local frontend_client="$4"
    local backend_client="$5"
    local env_file="$project_root/.env"
    
    if [ ! -f "$env_file" ]; then
        echo "⚠️  .env file not found, skipping Keycloak configuration update"
        return 0
    fi
    
    echo "📝 Updating .env file with Keycloak configuration..."
    
    # Create backup
    cp "$env_file" "$env_file.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Remove existing Keycloak settings if they exist
    sed -i '/^KEYCLOAK_URL=/d' "$env_file"
    sed -i '/^KEYCLOAK_INTERNAL_URL=/d' "$env_file"
    sed -i '/^KEYCLOAK_REALM=/d' "$env_file"
    sed -i '/^KEYCLOAK_CLIENT_ID=/d' "$env_file"
    sed -i '/^KEYCLOAK_CLIENT_ID_WEB=/d' "$env_file"
    sed -i '/^KEYCLOAK_ENABLED=/d' "$env_file"
    
    # Add new Keycloak settings at the end
    cat >> "$env_file" << EOF

# --- Keycloak Authentication (Required for Web UI) ---
KEYCLOAK_URL="$keycloak_url"
KEYCLOAK_INTERNAL_URL=""
KEYCLOAK_REALM="$realm"
KEYCLOAK_CLIENT_ID="$backend_client"
KEYCLOAK_CLIENT_ID_WEB="$frontend_client"
KEYCLOAK_ENABLED="true"
EOF
    
    echo "✅ .env file updated with Keycloak configuration"
    echo "   - KEYCLOAK_URL: $keycloak_url"
    echo "   - KEYCLOAK_REALM: $realm"
    echo "   - KEYCLOAK_CLIENT_ID: $backend_client"
    echo "   - KEYCLOAK_CLIENT_ID_WEB: $frontend_client"
}

# _show_available_roles
# Displays available roles with descriptions.
_show_available_roles() {
    echo "Available roles:"
    echo "  1) statechecker:admin - Full access (all permissions)"
    echo "  2) statechecker:read  - View-only access to monitoring data"
    echo ""
    echo "Role presets:"
    echo "  admin  = All roles (1-2)"
    echo "  viewer = read only (2)"
}

# _parse_role_input
# Converts role input (numbers, names, presets) to comma-separated role list.
# Args: $1 = user input
# Returns: comma-separated role list via echo
_parse_role_input() {
    local input="$1"
    local roles=""
    
    # Handle presets
    case "$input" in
        admin|Admin|ADMIN)
            echo "statechecker:admin,statechecker:read"
            return
            ;;
        viewer|Viewer|VIEWER|read|Read|READ)
            echo "statechecker:read"
            return
            ;;
    esac
    
    # Handle comma-separated numbers or role names
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | tr -d ' ')
        case "$part" in
            1|statechecker:admin) roles="${roles:+$roles,}statechecker:admin" ;;
            2|statechecker:read) roles="${roles:+$roles,}statechecker:read" ;;
            *) 
                # Try to use as-is if it looks like a role
                if [[ "$part" == statechecker:* ]]; then
                    roles="${roles:+$roles,}$part"
                fi
                ;;
        esac
    done
    
    echo "$roles"
}

# _prompt_create_user
# Interactive prompt to create a single user.
# Returns user spec via echo in format: username:password:role1,role2
# Returns empty string if user chooses to skip.
_prompt_create_user() {
    local default_username="${1:-}"
    
    echo ""
    echo "👤 Create User"
    echo "─────────────────────────────────────"
    
    echo -n "Username${default_username:+ [$default_username]}: "
    read username
    username="${username:-$default_username}"
    
    if [ -z "$username" ]; then
        echo "⚠️  Username is required"
        return 1
    fi
    
    # Password with confirmation
    while true; do
        echo -n "Password: "
        read -s password
        echo ""
        
        if [ -z "$password" ]; then
            echo "⚠️  Password is required"
            continue
        fi
        
        echo -n "Confirm password: "
        read -s password_confirm
        echo ""
        
        if [ "$password" != "$password_confirm" ]; then
            echo "❌ Passwords do not match. Please try again."
            echo ""
            continue
        fi
        
        break
    done
    
    echo ""
    _show_available_roles
    echo ""
    echo -n "Roles (numbers, names, or preset) [admin]: "
    read role_input
    role_input="${role_input:-admin}"
    
    local roles
    roles=$(_parse_role_input "$role_input")
    
    if [ -z "$roles" ]; then
        echo "⚠️  At least one role is required"
        return 1
    fi
    
    echo "✅ User: $username with roles: $roles"
    export USER_SPEC="$username:$password:$roles"
}

# _collect_users_interactive
# Collects users interactively in a loop.
# Returns user args for bootstrap script via echo.
_collect_users_interactive() {
    local user_args=""
    local user_count=0
    local created_users=""
    
    echo ""
    echo "👥 User Creation"
    echo "═══════════════════════════════════════"
    echo "At least one user is required to access the Statechecker UI."
    echo ""
    
    while true; do
        _prompt_create_user
        local user_spec="${USER_SPEC:-}"
        if [ -n "$user_spec" ]; then
            user_args="$user_args --user $user_spec"
            user_count=$((user_count + 1))
            local username
            username=$(echo "$user_spec" | cut -d: -f1)
            created_users="${created_users:+$created_users, }$username"
        fi
        
        echo ""
        if [ $user_count -eq 0 ]; then
            echo "⚠️  At least one user is required."
            echo -n "Create a user? (Y/n): "
            read continue_input
            if [[ "$continue_input" =~ ^[Nn]$ ]]; then
                echo "❌ Cannot proceed without at least one user"
                return 1
            fi
        else
            echo -n "Create another user? (y/N): "
            read continue_input
            if [[ ! "$continue_input" =~ ^[Yy]$ ]]; then
                break
            fi
        fi
    done
    
    echo ""
    echo "📋 Users to create: $created_users"
    export USER_ARGS="$user_args"
}

# handle_keycloak_bootstrap
# Bootstraps Keycloak realm, roles, and users with improved error handling.
handle_keycloak_bootstrap() {
    local project_root
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local scripts_dir="$project_root/scripts"
    local bootstrap_image="statechecker-keycloak-bootstrap"
    
    echo "🔐 Keycloak Bootstrap for Statechecker"
    echo ""
    
    # Load defaults from template first, then override with .env if it exists
    local env_template="$project_root/setup/.env.template"
    local keycloak_url="http://localhost:9090"
    local keycloak_realm="statechecker"
    local frontend_url="http://localhost:8788"
    local backend_url="http://localhost:8787"
    
    # Load from template if exists
    echo "🔍 Debug: Looking for template at: $env_template"
    if [ -f "$env_template" ]; then
        echo "✅ Debug: Template found, loading defaults..."
        keycloak_url=$(grep "^KEYCLOAK_URL=" "$env_template" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_url="http://localhost:9090"
        keycloak_realm=$(grep "^KEYCLOAK_REALM=" "$env_template" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_realm="statechecker"
        frontend_url=$(grep "^WEB_URL=" "$env_template" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || frontend_url="http://localhost:8788"
        backend_url=$(grep "^API_URL=" "$env_template" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || backend_url="http://localhost:8787"
        echo "🔍 Debug: Loaded realm='$keycloak_realm'"
    else
        echo "❌ Debug: Template not found, using hardcoded defaults"
        echo "🔍 Debug: Project root: $project_root"
        echo "🔍 Debug: Files in setup dir:"
        ls -la "$project_root/setup/" 2>/dev/null || echo "Setup dir not found"
    fi
    
    # Override with actual .env if it exists
    if [ -f "$project_root/.env" ]; then
        keycloak_url=$(grep "^KEYCLOAK_URL=" "$project_root/.env" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_url="$keycloak_url"
        keycloak_realm=$(grep "^KEYCLOAK_REALM=" "$project_root/.env" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_realm="$keycloak_realm"
        frontend_url=$(grep "^WEB_URL=" "$project_root/.env" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || frontend_url="$frontend_url"
        backend_url=$(grep "^API_URL=" "$project_root/.env" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || backend_url="$backend_url"
    fi
    
    # Ensure URLs have protocol for display in prompts
    if [[ "$frontend_url" != http://* && "$frontend_url" != https://* ]]; then
        frontend_url="https://$frontend_url"
    fi
    if [[ "$backend_url" != http://* && "$backend_url" != https://* ]]; then
        backend_url="https://$backend_url"
    fi
    
    # Check if Keycloak is reachable, ask for URL if not reachable
    local url_reachable=false
    while [ "$url_reachable" = false ]; do
        echo "🔍 Checking Keycloak at $keycloak_url..."
        if curl -s --connect-timeout 5 "$keycloak_url/" >/dev/null 2>&1; then
            echo "✅ Keycloak is reachable"
            url_reachable=true
        else
            echo ""
            echo "❌ Cannot reach Keycloak at $keycloak_url"
            echo ""
            echo -n "Enter correct Keycloak URL (or press Enter to retry default): "
            read input_url
            if [ -n "$input_url" ]; then
                keycloak_url="$input_url"
            else
                echo "Retrying default URL..."
            fi
            echo ""
        fi
    done
    echo ""
    
    # Check if we can run Python directly or need Docker
    local use_docker=false
    if command -v python3 >/dev/null 2>&1 && python3 -c "import requests" 2>/dev/null; then
        echo "✅ Using local Python3 with requests module"
        use_docker=false
    else
        echo "⚠️  Python3 or requests module not available, using Docker"
        use_docker=true
        
        # Build bootstrap image if needed
        if ! docker image inspect "$bootstrap_image" >/dev/null 2>&1; then
            echo "🐳 Building bootstrap image..."
            if ! docker build -t "$bootstrap_image" "$scripts_dir"; then
                echo "❌ Failed to build bootstrap image"
                return 1
            fi
        fi
    fi
    
    # Get admin credentials
    echo "📝 Bootstrap Configuration"
    echo -n "Keycloak admin username [admin]: "
    read admin_user
    admin_user="${admin_user:-admin}"
    
    echo "🔑 Please enter the Keycloak admin password manually"
    echo -n "🔑 Admin password: "
    read -s admin_password
    echo ""
    if [ -z "$admin_password" ]; then
        echo "❌ Admin password is required"
        return 1
    fi
    
    echo -n "Realm name [$keycloak_realm]: "
    read realm
    realm="${realm:-$keycloak_realm}"
    
    echo -n "Frontend client ID [statechecker-frontend]: "
    read frontend_client
    frontend_client="${frontend_client:-statechecker-frontend}"
    
    echo -n "Backend client ID [statechecker-backend]: "
    read backend_client
    backend_client="${backend_client:-statechecker-backend}"
    
    echo -n "Frontend client root URL [$frontend_url]: "
    read frontend_client_url
    frontend_client_url="${frontend_client_url:-$frontend_url}"
    if [[ "$frontend_client_url" != http://* && "$frontend_client_url" != https://* ]]; then
        frontend_client_url="https://$frontend_client_url"
    fi
    
    echo -n "Backend API client root URL [$backend_url]: "
    read backend_api_client_url
    backend_api_client_url="${backend_api_client_url:-$backend_url}"
    if [[ "$backend_api_client_url" != http://* && "$backend_api_client_url" != https://* ]]; then
        backend_api_client_url="https://$backend_api_client_url"
    fi
    
    echo ""
    echo "✅ Roles to be created:"
    echo "   - statechecker:read  (view monitoring data)"
    echo "   - statechecker:admin (full access)"
    
    # Collect users interactively
    _collect_users_interactive
    local user_args=$?
    if [ $user_args -ne 0 ]; then
        echo "❌ Bootstrap cancelled - at least one user is required"
        return 1
    fi
    user_args="${USER_ARGS:-}"
    
    # Try bootstrap with retry loop for auth failures
    local max_attempts=3
    local attempt=1
    local exit_code=0
    local bootstrap_log="/tmp/bootstrap_output.log"
    
    while [ $attempt -le $max_attempts ]; do
        echo ""
        if [ $attempt -gt 1 ]; then
            echo "🔄 Attempt $attempt of $max_attempts"
        fi
        echo "🚀 Running bootstrap..."
        echo "  URL: $keycloak_url"
        echo "  Admin: $admin_user"
        echo "  Realm: $realm"
        echo ""
        
        local bootstrap_script
        bootstrap_script="$scripts_dir/keycloak_bootstrap.py"
        
        set +e
        if [ "$use_docker" = true ]; then
            docker run --rm --network host "$bootstrap_image" \
                --base-url "$keycloak_url" \
                --admin-user "$admin_user" \
                --admin-password "$admin_password" \
                --realm "$realm" \
                --frontend-client-id "$frontend_client" \
                --backend-client-id "$backend_client" \
                --frontend-root-url "$frontend_client_url" \
                --api-root-url "$backend_api_client_url" \
                --role statechecker:read --role statechecker:admin \
                --assign-service-account-role statechecker:admin \
                $user_args >"$bootstrap_log" 2>&1
            exit_code=$?
        else
            python3 "$bootstrap_script" \
                --base-url "$keycloak_url" \
                --admin-user "$admin_user" \
                --admin-password "$admin_password" \
                --realm "$realm" \
                --frontend-client-id "$frontend_client" \
                --backend-client-id "$backend_client" \
                --frontend-root-url "$frontend_client_url" \
                --api-root-url "$backend_api_client_url" \
                --role statechecker:read --role statechecker:admin \
                --assign-service-account-role statechecker:admin \
                $user_args >"$bootstrap_log" 2>&1
            exit_code=$?
        fi
        set -e
        
        # Always show output for debugging
        if [ -f "$bootstrap_log" ]; then
            echo "Bootstrap output:"
            cat "$bootstrap_log" | sed 's/^/  /'
        fi
        
        if grep -q "invalid_grant\|Invalid user credentials" "$bootstrap_log"; then
            echo "⚠️  Authentication failed with current credentials"
            
            if [ $attempt -eq $max_attempts ]; then
                echo "❌ Maximum attempts reached. Bootstrap failed."
                echo ""
                echo "Please check:"
                echo "  1. The admin username and password are correct"
                echo "  2. The Keycloak URL is accessible"
                echo "  3. The admin user exists in the master realm"
                echo ""
                rm -f "$bootstrap_log"
                return 1
            fi
            
            echo ""
            echo "🔑 Please enter new credentials:"
            echo -n "Username [$admin_user]: "
            read new_user
            admin_user="${new_user:-$admin_user}"
            echo -n "Password: "
            read -s admin_password
            echo ""
            if [ -z "$admin_password" ]; then
                echo "❌ Password cannot be empty"
                rm -f "$bootstrap_log"
                return 1
            fi
            
            attempt=$((attempt + 1))
            continue
        fi
        
        if [ $exit_code -ne 0 ]; then
            echo "❌ Bootstrap failed."
            echo ""
            echo "Output (last 20 lines):"
            tail -n 20 "$bootstrap_log"
            rm -f "$bootstrap_log"
            return 1
        fi
        
        break
    done
    
    if [ $exit_code -eq 0 ]; then
        echo ""
        echo "✅ Keycloak realm '$realm' bootstrapped successfully!"
        echo ""
        echo "📋 Created:"
        echo "  Realm: $realm"
        echo "  Frontend client: $frontend_client"
        echo "  Backend client: $backend_client"
        echo "  Roles: statechecker:admin, statechecker:read"
        echo ""
        
        # Update .env file with Keycloak configuration
        _update_env_with_keycloak_config "$project_root" "$keycloak_url" "$realm" "$frontend_client" "$backend_client"
        
        echo ""
        echo "🔑 IMPORTANT: Copy the backend_client_secret from the JSON output above!"
        echo "   Look for: \"backend_client_secret\": \"<SECRET_VALUE>\""
        echo ""
        
        echo "📝 Complete Setup Instructions:"
        echo ""
        echo "   1️⃣  Create the Keycloak client secret in Docker Swarm:"
        echo "      echo '<PASTE_SECRET_HERE>' | docker secret create STATECHECKER_SERVER_KEYCLOAK_CLIENT_SECRET -"
        echo ""
        echo "   2️⃣  Verify all required secrets exist:"
        echo "      docker secret ls | grep STATECHECKER_SERVER"
        echo ""
        echo "   3️⃣  If you need to create other required secrets:"
        echo "      - Run menu option 11: 'Create required secrets'"
        echo "      - Or run: ./quick-start.sh → option 11"
        echo ""
        echo "   4️⃣  Deploy the stack:"
        echo "      - Run menu option 1: 'Deploy stack'"
        echo "      - Or run: docker stack deploy -c swarm-stack.yml statechecker"
        echo ""
        echo "   5️⃣  Access the Statechecker UI:"
        echo "      - URL: https://statechecker.fe-wi.com (or your WEB_URL)"
        echo "      - Login with the user(s) you created during bootstrap"
        echo ""
        echo "📋 Your .env file has been updated with:"
        echo "   - KEYCLOAK_URL: $keycloak_url"
        echo "   - KEYCLOAK_REALM: $realm"
        echo "   - KEYCLOAK_CLIENT_ID: $backend_client"
        echo "   - KEYCLOAK_CLIENT_ID_WEB: $frontend_client"
        echo ""
        echo "⚠️  Remember: The client secret is ONLY shown once in the bootstrap output!"
        echo "   If you lose it, you'll need to regenerate it in Keycloak or re-run bootstrap."
        rm -f "$bootstrap_log"
    else
        echo "❌ Bootstrap failed"
        return 1
    fi
}

# handle_keycloak_create_user
# Creates a user in an existing Keycloak realm.
handle_keycloak_create_user() {
    local project_root
    project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local scripts_dir="$project_root/scripts"
    
    echo "👤 Create Keycloak User"
    echo ""
    
    # Load defaults from template first, then override with .env if it exists
    local env_template="$project_root/setup/.env.template"
    local keycloak_url="http://localhost:9090"
    local keycloak_realm="statechecker"
    
    # Load from template if exists
    if [ -f "$env_template" ]; then
        keycloak_url=$(grep "^KEYCLOAK_URL=" "$env_template" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_url="http://localhost:9090"
        keycloak_realm=$(grep "^KEYCLOAK_REALM=" "$env_template" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_realm="statechecker"
    fi
    
    # Override with actual .env if it exists
    if [ -f "$project_root/.env" ]; then
        keycloak_url=$(grep "^KEYCLOAK_URL=" "$project_root/.env" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_url="$keycloak_url"
        keycloak_realm=$(grep "^KEYCLOAK_REALM=" "$project_root/.env" 2>/dev/null | head -n1 | cut -d'=' -f2- | tr -d ' "') || keycloak_realm="$keycloak_realm"
    fi
    
    # Check if Keycloak is reachable
    echo "🔍 Checking Keycloak at $keycloak_url..."
    if ! curl -s --connect-timeout 5 "$keycloak_url/" >/dev/null 2>&1; then
        echo "❌ Cannot reach Keycloak at $keycloak_url"
        echo -n "Enter correct Keycloak URL: "
        read keycloak_url
        if [ -z "$keycloak_url" ]; then
            echo "❌ Keycloak URL is required"
            return 1
        fi
    fi
    echo "✅ Keycloak is reachable"
    echo ""
    
    # Get admin credentials
    echo -n "Keycloak admin username [admin]: "
    read admin_user
    admin_user="${admin_user:-admin}"
    
    echo -n "🔑 Admin password: "
    read -s admin_password
    echo ""
    if [ -z "$admin_password" ]; then
        echo "❌ Admin password is required"
        return 1
    fi
    
    echo -n "Realm name [$keycloak_realm]: "
    read realm
    realm="${realm:-$keycloak_realm}"
    
    # Collect user info
    _prompt_create_user
    local user_spec="${USER_SPEC:-}"
    if [ -z "$user_spec" ]; then
        echo "❌ User creation cancelled"
        return 1
    fi
    
    # Check if we can run Python directly
    local bootstrap_script="$scripts_dir/keycloak_bootstrap.py"
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c "import requests" 2>/dev/null; then
        echo "❌ Python3 with requests module is required"
        echo "   Install with: pip3 install requests"
        return 1
    fi
    
    echo ""
    echo "🚀 Creating user..."
    
    set +e
    python3 "$bootstrap_script" \
        --base-url "$keycloak_url" \
        --admin-user "$admin_user" \
        --admin-password "$admin_password" \
        --realm "$realm" \
        --frontend-client-id "statechecker-frontend" \
        --backend-client-id "statechecker-backend" \
        --frontend-root-url "https://placeholder.local" \
        --api-root-url "https://placeholder.local/api" \
        --user "$user_spec" 2>&1
    local exit_code=$?
    set -e
    
    if [ $exit_code -eq 0 ]; then
        local username
        username=$(echo "$user_spec" | cut -d: -f1)
        echo ""
        echo "✅ User '$username' created successfully!"
    else
        echo ""
        echo "❌ Failed to create user"
        return 1
    fi
}
