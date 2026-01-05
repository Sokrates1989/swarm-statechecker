#!/bin/bash

# Read the password from the secret file.
if [[ -f /run/secrets/STATECHECKER_SERVER_DB_USER_PW ]]; then
    STATECHECKER_SERVER_DB_USER_PW=$(cat /run/secrets/STATECHECKER_SERVER_DB_USER_PW)
else
    echo "Secret file not found"
    exit 1
fi

# Apply migrations.
for f in /scripts/*.sql; do
    echo "Applying migration $f"
    mysql -h "${MYSQL_HOST:-db}" -u "$MYSQL_USER" -p"$STATECHECKER_SERVER_DB_USER_PW" "$MYSQL_DATABASE" < "$f"
done