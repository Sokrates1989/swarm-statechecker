#!/bin/bash

set -euo pipefail

# Read the password from the secret file.
if [[ -f /run/secrets/STATECHECKER_SERVER_DB_USER_PW ]]; then
    STATECHECKER_SERVER_DB_USER_PW="$(tr -d '\r\n' < /run/secrets/STATECHECKER_SERVER_DB_USER_PW)"
else
    echo "Secret file not found"
    exit 1
fi

MYSQL_HOST_VALUE="${MYSQL_HOST:-db}"
MYSQL_DATABASE_VALUE="${MYSQL_DATABASE:-state_checker}"
MYSQL_USER_VALUE="${MYSQL_USER:-state_checker}"

echo "Waiting for MySQL at ${MYSQL_HOST_VALUE} to become ready..."
for i in $(seq 1 60); do
    if mysql -h "${MYSQL_HOST_VALUE}" -u "${MYSQL_USER_VALUE}" -p"${STATECHECKER_SERVER_DB_USER_PW}" -e "SELECT 1" "${MYSQL_DATABASE_VALUE}" >/dev/null 2>&1; then
        echo "MySQL is ready."
        break
    fi

    if [ "$i" -eq 60 ]; then
        echo "ERROR: MySQL did not become ready in time."
        exit 1
    fi

    sleep 2
done

# Apply migrations.
for f in /scripts/*.sql; do
    echo "Applying migration $f"
    if ! mysql -h "${MYSQL_HOST_VALUE}" -u "${MYSQL_USER_VALUE}" -p"${STATECHECKER_SERVER_DB_USER_PW}" "${MYSQL_DATABASE_VALUE}" < "$f"; then
        echo "ERROR: Migration $f failed."
        exit 1
    fi
done

echo "All migrations applied successfully."