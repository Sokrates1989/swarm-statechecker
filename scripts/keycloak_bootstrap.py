"""
Module: keycloak_bootstrap.py

Description:
    Helper utility for bootstrapping a Keycloak realm with default roles,
    backend/front-end clients, and initial users for Statechecker.
    This script uses the Keycloak Admin REST API to automate creation of
    realms and users, then prints the generated backend client secret.

Dependencies:
    - requests

Usage:
    python scripts/keycloak_bootstrap.py \
        --base-url http://localhost:9090 \
        --admin-user admin \
        --admin-password admin \
        --realm statechecker \
        --frontend-client-id statechecker-frontend \
        --backend-client-id statechecker-backend \
        --frontend-root-url http://localhost:8788 \
        --api-root-url http://localhost:8787 \
        --user admin:admin:statechecker:admin

Granular Roles:
    - statechecker:admin - Full access (all permissions)
    - statechecker:read  - View-only access to monitoring data
"""

from __future__ import annotations

import argparse
import dataclasses
import json
from typing import Iterable, Sequence

import requests


@dataclasses.dataclass(frozen=True)
class UserSpec:
    """Definition for a user to create in Keycloak.

    Attributes:
        username: Username for the new user.
        password: Password to set for the user.
        roles: Realm roles to assign to the user.
    """

    username: str
    password: str
    roles: list[str]


@dataclasses.dataclass(frozen=True)
class ClientSpec:
    """Definition for a Keycloak client.

    Attributes:
        client_id: Client identifier.
        payload: JSON payload to send to Keycloak.
    """

    client_id: str
    payload: dict[str, object]


class KeycloakBootstrapError(RuntimeError):
    """Raised when bootstrap operations fail."""


def parse_user_specs(raw_specs: Sequence[str]) -> list[UserSpec]:
    """Parse user specification strings into UserSpec objects.

    Args:
        raw_specs: Iterable of strings in the format "username:password:role1,role2".

    Returns:
        list[UserSpec]: Parsed user specifications.

    Raises:
        KeycloakBootstrapError: When a spec string is invalid.
    """

    users: list[UserSpec] = []
    for spec in raw_specs:
        parts = spec.split(":")
        if len(parts) < 3:
            raise KeycloakBootstrapError(
                f"Invalid user spec '{spec}'. Use username:password:role1,role2"
            )
        username, password, roles_raw = parts[0], parts[1], ":".join(parts[2:])
        roles = [role.strip() for role in roles_raw.split(",") if role.strip()]
        if not username or not password or not roles:
            raise KeycloakBootstrapError(
                f"Invalid user spec '{spec}'. Username, password, and roles are required."
            )
        users.append(UserSpec(username=username, password=password, roles=roles))
    return users


def get_admin_token(base_url: str, username: str, password: str) -> str:
    """Request an admin access token from Keycloak.

    Args:
        base_url: Keycloak base URL.
        username: Admin username.
        password: Admin password.

    Returns:
        str: Access token.

    Raises:
        KeycloakBootstrapError: When the token request fails.
    """

    token_endpoint = f"{base_url.rstrip('/')}/realms/master/protocol/openid-connect/token"
    response = requests.post(
        token_endpoint,
        data={
            "grant_type": "password",
            "client_id": "admin-cli",
            "username": username,
            "password": password,
        },
        timeout=20,
    )
    if response.status_code != 200:
        raise KeycloakBootstrapError(
            f"Failed to obtain admin token: {response.status_code} {response.text}"
        )
    token = response.json().get("access_token")
    if not token:
        raise KeycloakBootstrapError("Keycloak admin token response missing access_token")
    return token


def request_with_token(
    method: str,
    base_url: str,
    token: str,
    path: str,
    json_body: dict | list | None = None,
    params: dict | None = None,
) -> requests.Response:
    """Send an authenticated request to the Keycloak admin API.

    Args:
        method: HTTP method.
        base_url: Keycloak base URL.
        token: Bearer token.
        path: API path (e.g., /admin/realms).
        json_body: Optional JSON body.
        params: Optional query params.

    Returns:
        requests.Response: Response from Keycloak.
    """

    url = f"{base_url.rstrip('/')}{path}"
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    return requests.request(
        method,
        url,
        headers=headers,
        json=json_body,
        params=params,
        timeout=20,
    )


def ensure_realm(base_url: str, token: str, realm: str, display_name: str) -> None:
    """Ensure a realm exists, creating it if needed.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        display_name: Display name for the realm.

    Raises:
        KeycloakBootstrapError: When realm creation fails unexpectedly.
    """

    response = request_with_token("GET", base_url, token, f"/admin/realms/{realm}")
    if response.status_code == 200:
        return
    if response.status_code not in (404, 400):
        raise KeycloakBootstrapError(
            f"Failed to check realm '{realm}': {response.status_code} {response.text}"
        )

    payload = {
        "realm": realm,
        "displayName": display_name,
        "enabled": True,
        "loginWithEmailAllowed": True,
        "resetPasswordAllowed": True,
        "registrationAllowed": False,
    }
    create_response = request_with_token("POST", base_url, token, "/admin/realms", payload)
    if create_response.status_code not in (201, 204):
        raise KeycloakBootstrapError(
            f"Failed to create realm '{realm}': {create_response.status_code} {create_response.text}"
        )


# Granular role definitions with descriptions for Statechecker
GRANULAR_ROLES = {
    "statechecker:read": "View monitoring data and status (LOW criticality)",
    "statechecker:admin": "Full access including configuration changes",
}

DEFAULT_ROLES = list(GRANULAR_ROLES.keys())


def role_exists(base_url: str, token: str, realm: str, role: str) -> bool:
    """Check if a realm role exists.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        role: Role name to check.

    Returns:
        bool: True if the role exists.
    """
    response = request_with_token(
        "GET",
        base_url,
        token,
        f"/admin/realms/{realm}/roles/{role}",
    )
    return response.status_code == 200


def ensure_roles(
    base_url: str, token: str, realm: str, roles: Iterable[str], descriptions: dict[str, str] | None = None
) -> None:
    """Ensure realm roles exist.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        roles: Role names to ensure.
        descriptions: Optional dict mapping role names to descriptions.

    Raises:
        KeycloakBootstrapError: When role creation fails unexpectedly.
    """
    if descriptions is None:
        descriptions = GRANULAR_ROLES

    for role in roles:
        if role_exists(base_url, token, realm, role):
            print(f"  ✓ Role '{role}' already exists")
            continue

        description = descriptions.get(role, f"Role {role}")
        response = request_with_token(
            "POST",
            base_url,
            token,
            f"/admin/realms/{realm}/roles",
            {"name": role, "description": description},
        )
        if response.status_code in (201, 204):
            print(f"  + Role '{role}' created")
            continue
        if response.status_code == 409:
            print(f"  ✓ Role '{role}' already exists (conflict)")
            continue
        raise KeycloakBootstrapError(
            f"Failed to create role '{role}': {response.status_code} {response.text}"
        )


def resolve_client_id(base_url: str, token: str, realm: str, client_id: str) -> str | None:
    """Resolve a client UUID by client ID.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        client_id: Client ID to search for.

    Returns:
        str | None: Client UUID if found.
    """

    response = request_with_token(
        "GET",
        base_url,
        token,
        f"/admin/realms/{realm}/clients",
        params={"clientId": client_id},
    )
    if response.status_code != 200:
        return None
    results = response.json()
    if not results:
        return None
    return results[0].get("id")


def ensure_client(base_url: str, token: str, realm: str, client: ClientSpec) -> str:
    """Ensure a client exists and return its UUID.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        client: Client specification.

    Returns:
        str: Client UUID.

    Raises:
        KeycloakBootstrapError: When client creation fails.
    """

    client_uuid = resolve_client_id(base_url, token, realm, client.client_id)
    if client_uuid:
        return client_uuid

    response = request_with_token(
        "POST",
        base_url,
        token,
        f"/admin/realms/{realm}/clients",
        client.payload,
    )
    if response.status_code not in (201, 204):
        raise KeycloakBootstrapError(
            f"Failed to create client '{client.client_id}': {response.status_code} {response.text}"
        )

    client_uuid = resolve_client_id(base_url, token, realm, client.client_id)
    if not client_uuid:
        raise KeycloakBootstrapError(f"Unable to resolve client '{client.client_id}' after creation")
    return client_uuid


def get_client_secret(base_url: str, token: str, realm: str, client_uuid: str) -> str:
    """Fetch a client secret.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        client_uuid: Client UUID.

    Returns:
        str: Client secret.

    Raises:
        KeycloakBootstrapError: When the secret cannot be retrieved.
    """

    response = request_with_token(
        "GET",
        base_url,
        token,
        f"/admin/realms/{realm}/clients/{client_uuid}/client-secret",
    )
    if response.status_code != 200:
        raise KeycloakBootstrapError(
            f"Failed to fetch client secret: {response.status_code} {response.text}"
        )
    secret = response.json().get("value")
    if not secret:
        raise KeycloakBootstrapError("Client secret response missing value")
    return secret


def ensure_user(base_url: str, token: str, realm: str, user: UserSpec) -> str:
    """Ensure a user exists and return its UUID.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        user: User specification.

    Returns:
        str: User UUID.
    """

    response = request_with_token(
        "GET",
        base_url,
        token,
        f"/admin/realms/{realm}/users",
        params={"username": user.username},
    )
    if response.status_code == 200 and response.json():
        return response.json()[0].get("id")

    payload = {"username": user.username, "enabled": True, "emailVerified": True}
    create_response = request_with_token(
        "POST",
        base_url,
        token,
        f"/admin/realms/{realm}/users",
        payload,
    )
    if create_response.status_code not in (201, 204):
        raise KeycloakBootstrapError(
            f"Failed to create user '{user.username}': {create_response.status_code} {create_response.text}"
        )

    lookup = request_with_token(
        "GET",
        base_url,
        token,
        f"/admin/realms/{realm}/users",
        params={"username": user.username},
    )
    if lookup.status_code == 200 and lookup.json():
        return lookup.json()[0].get("id")
    raise KeycloakBootstrapError(f"Unable to resolve user '{user.username}' after creation")


def set_user_password(base_url: str, token: str, realm: str, user_id: str, password: str) -> None:
    """Set a user's password.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        user_id: User UUID.
        password: Plaintext password.

    Raises:
        KeycloakBootstrapError: When password update fails.
    """

    payload = {"type": "password", "value": password, "temporary": False}
    response = request_with_token(
        "PUT",
        base_url,
        token,
        f"/admin/realms/{realm}/users/{user_id}/reset-password",
        payload,
    )
    if response.status_code not in (204,):
        raise KeycloakBootstrapError(
            f"Failed to set password for user: {response.status_code} {response.text}"
        )


def get_role_representations(
    base_url: str, token: str, realm: str, roles: Iterable[str], skip_missing: bool = False
) -> tuple[list[dict[str, object]], list[str]]:
    """Fetch role representations for assignment.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        roles: Role names.
        skip_missing: If True, skip missing roles instead of raising an error.

    Returns:
        tuple[list[dict[str, object]], list[str]]: Role representations and list of missing roles.
    """

    representations = []
    missing_roles = []
    for role in roles:
        response = request_with_token(
            "GET",
            base_url,
            token,
            f"/admin/realms/{realm}/roles/{role}",
        )
        if response.status_code != 200:
            if skip_missing:
                missing_roles.append(role)
                continue
            raise KeycloakBootstrapError(
                f"Failed to fetch role '{role}': {response.status_code} {response.text}"
            )
        representations.append(response.json())
    return representations, missing_roles


def assign_realm_roles(
    base_url: str, token: str, realm: str, user_id: str, roles: Iterable[str], username: str = ""
) -> None:
    """Assign realm roles to a user.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        user_id: User UUID.
        roles: Role names.
        username: Username for logging purposes.

    Raises:
        KeycloakBootstrapError: When role assignment fails.
    """
    roles_list = list(roles)
    role_reps, missing_roles = get_role_representations(base_url, token, realm, roles_list, skip_missing=True)
    
    if missing_roles:
        print(f"  ⚠ Warning: Skipping missing roles for user '{username}': {', '.join(missing_roles)}")
    
    if not role_reps:
        print(f"  ⚠ No valid roles to assign to user '{username}'")
        return
    
    response = request_with_token(
        "POST",
        base_url,
        token,
        f"/admin/realms/{realm}/users/{user_id}/role-mappings/realm",
        role_reps,
    )
    if response.status_code not in (204,):
        raise KeycloakBootstrapError(
            f"Failed to assign roles to user: {response.status_code} {response.text}"
        )
    assigned = [r.get('name', '?') for r in role_reps]
    print(f"  ✓ Assigned roles to '{username}': {', '.join(assigned)}")


def assign_service_account_role(
    base_url: str, token: str, realm: str, client_uuid: str, role: str
) -> None:
    """Assign a realm role to the service-account user for a client.

    Args:
        base_url: Keycloak base URL.
        token: Admin access token.
        realm: Realm name.
        client_uuid: Client UUID.
        role: Role name.
    """

    response = request_with_token(
        "GET",
        base_url,
        token,
        f"/admin/realms/{realm}/clients/{client_uuid}/service-account-user",
    )
    if response.status_code != 200:
        raise KeycloakBootstrapError(
            f"Failed to fetch service account user: {response.status_code} {response.text}"
        )
    user_id = response.json().get("id")
    if not user_id:
        raise KeycloakBootstrapError("Service account user id missing")
    assign_realm_roles(base_url, token, realm, user_id, [role], "service-account")


def build_client_specs(
    frontend_client_id: str,
    backend_client_id: str,
    frontend_root_url: str,
    api_root_url: str,
) -> tuple[ClientSpec, ClientSpec]:
    """Build frontend and backend client specs.

    Args:
        frontend_client_id: Public client ID.
        backend_client_id: Confidential client ID.
        frontend_root_url: Base URL for frontend.
        api_root_url: Base URL for API.

    Returns:
        tuple[ClientSpec, ClientSpec]: Frontend and backend client specs.
    """

    frontend_payload = {
        "clientId": frontend_client_id,
        "name": frontend_client_id,
        "protocol": "openid-connect",
        "publicClient": True,
        "standardFlowEnabled": True,
        "directAccessGrantsEnabled": True,
        "implicitFlowEnabled": False,
        "serviceAccountsEnabled": False,
        "rootUrl": frontend_root_url,
        "baseUrl": "/",
        "redirectUris": [f"{frontend_root_url.rstrip('/') }/*"],
        "webOrigins": [frontend_root_url, api_root_url, "+"],
        "attributes": {"pkce.code.challenge.method": "S256"},
    }

    backend_payload = {
        "clientId": backend_client_id,
        "name": backend_client_id,
        "protocol": "openid-connect",
        "publicClient": False,
        "standardFlowEnabled": False,
        "directAccessGrantsEnabled": False,
        "implicitFlowEnabled": False,
        "serviceAccountsEnabled": True,
        "bearerOnly": False,
        "rootUrl": api_root_url,
        "baseUrl": "/",
    }

    return ClientSpec(frontend_client_id, frontend_payload), ClientSpec(backend_client_id, backend_payload)


def run_bootstrap(args: argparse.Namespace) -> None:
    """Execute the bootstrap flow.

    Args:
        args: Parsed CLI arguments.

    Raises:
        KeycloakBootstrapError: On failure.
    """

    user_roles = args.role if args.role else DEFAULT_ROLES
    users = parse_user_specs(args.user)

    token = get_admin_token(args.base_url, args.admin_user, args.admin_password)
    ensure_realm(args.base_url, token, args.realm, args.realm.replace("-", " ").title())
    
    print("\nEnsuring roles exist...")
    ensure_roles(args.base_url, token, args.realm, DEFAULT_ROLES)

    frontend_spec, backend_spec = build_client_specs(
        args.frontend_client_id,
        args.backend_client_id,
        args.frontend_root_url,
        args.api_root_url,
    )
    ensure_client(args.base_url, token, args.realm, frontend_spec)
    backend_uuid = ensure_client(args.base_url, token, args.realm, backend_spec)
    backend_secret = get_client_secret(args.base_url, token, args.realm, backend_uuid)

    print("\nCreating/updating users...")
    for user in users:
        print(f"  Processing user '{user.username}'...")
        user_id = ensure_user(args.base_url, token, args.realm, user)
        set_user_password(args.base_url, token, args.realm, user_id, user.password)
        assign_realm_roles(args.base_url, token, args.realm, user_id, user.roles, user.username)

    if args.assign_service_account_role:
        assign_service_account_role(
            args.base_url,
            token,
            args.realm,
            backend_uuid,
            args.assign_service_account_role,
        )

    summary = {
        "realm": args.realm,
        "frontend_client_id": args.frontend_client_id,
        "backend_client_id": args.backend_client_id,
        "backend_client_secret": backend_secret,
        "roles": user_roles,
        "users": [dataclasses.asdict(user) for user in users],
    }
    print("\nBootstrap completed. Summary:")
    print(json.dumps(summary, indent=2))


def build_arg_parser() -> argparse.ArgumentParser:
    """Build the argument parser.

    Returns:
        argparse.ArgumentParser: Configured parser.
    """

    parser = argparse.ArgumentParser(
        description="Bootstrap a Keycloak realm with clients, roles, and users for Statechecker.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument(
        "--base-url",
        default="http://localhost:9090",
        help="Keycloak base URL (port 9090 by default)",
    )
    parser.add_argument("--admin-user", default="admin", help="Keycloak admin username")
    parser.add_argument("--admin-password", default="admin", help="Keycloak admin password")
    parser.add_argument("--realm", default="statechecker", help="Realm name")
    parser.add_argument(
        "--frontend-client-id",
        default="statechecker-frontend",
        help="Frontend client ID",
    )
    parser.add_argument(
        "--backend-client-id",
        default="statechecker-backend",
        help="Backend client ID",
    )
    parser.add_argument(
        "--frontend-root-url",
        default="http://localhost:8788",
        help="Frontend base URL",
    )
    parser.add_argument(
        "--api-root-url",
        default="http://localhost:8787",
        help="API base URL",
    )
    parser.add_argument(
        "--role",
        action="append",
        default=[],
        help="Realm role to create (repeatable)",
    )
    parser.add_argument(
        "--user",
        action="append",
        default=[],
        help="User spec username:password:role1,role2 (repeatable)",
    )
    parser.add_argument(
        "--assign-service-account-role",
        default="statechecker:admin",
        help="Realm role to assign to backend service account",
    )
    return parser


def main() -> None:
    """CLI entry point."""

    parser = build_arg_parser()
    args = parser.parse_args()
    if not args.user:
        raise KeycloakBootstrapError("At least one --user specification is required.")
    run_bootstrap(args)


if __name__ == "__main__":
    main()
