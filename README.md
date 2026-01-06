# 🚀 swarm-statechecker README

Docker Swarm deployment for the **statechecker** stack (API + checker + MySQL + optional phpMyAdmin).

<br>

## Table of Contents

1. [📖 Overview](#overview)
2. [🧑‍💻 Usage](#usage)
3. [🛠️ Configuration / Installation / Setup](#configuration--installation--setup)
4. [🔐 Secrets](#secrets)
5. [🚀 Deploy](#deploy)
6. [🐞 Troubleshooting](#troubleshooting)
7. [🚀 Summary](#summary)

<br>

# 📖 Overview

This repository provides a `swarm-stack.yml` for deploying statechecker to Docker Swarm.

Services:

- **api**: FastAPI REST API
- **check**: periodic checker
- **db**: MySQL database
- **phpmyadmin**: optional DB UI

The stack uses `${IMAGE_NAME}:${IMAGE_VERSION}` (from `.env`) for both `api` and `check`.

<br>
<br>

# 🧑‍💻 Usage

```bash
# Run setup wizard
./quick-start.sh

# Deploy stack
docker stack deploy -c <(docker compose -f swarm-stack.yml --env-file .env config) statechecker-server
```

<br>
<br>

# 🛠️ Configuration / Installation / Setup

1) Copy template:

```bash
cp setup/.env.template .env
```

2) Edit `.env` and set:

- `STACK_NAME`
- `DATA_ROOT`
- `IMAGE_NAME`, `IMAGE_VERSION`
- Traefik settings (optional)

<br>
<br>

# 🔐 Secrets

Required secrets:

- `STATECHECKER_SERVER_AUTHENTICATION_TOKEN`
- `STATECHECKER_SERVER_DB_ROOT_USER_PW`
- `STATECHECKER_SERVER_DB_USER_PW`

Optional secrets:

- `STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON`
- `STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN`
- `STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD`

You can create secrets interactively via the quick-start wizard.

<br>
<br>

# 🚀 Deploy

Use the quick-start menu:

- `Deploy stack`

This renders `swarm-stack.yml` with env substitution and runs `docker stack deploy`.

<br>
<br>

# 🐞 Troubleshooting

## 🧩 Image not updated

If your swarm stack still runs old code:

- Ensure `.env` points to the correct `${IMAGE_NAME}:${IMAGE_VERSION}`
- Rebuild/push the image from `python/statechecker`
- Re-deploy the stack

## 🧩 Missing secrets

Run the quick-start secret checks and create missing required secrets.

## 🧩 Database init / restore

MySQL runs its init SQL only when the data directory is empty.

- Default schema init file:
  - `${DATA_ROOT}/install/database/state_checker.sql`

To restore from a SQL backup:

- Replace `${DATA_ROOT}/install/database/state_checker.sql` with your backup SQL file
- Move the existing `${DATA_ROOT}/db_data` directory to a backup location (do not delete unless you are sure)
- Re-deploy the stack

<br>
<br>

# 🚀 Summary

✅ Swarm deployment uses `${IMAGE_NAME}:${IMAGE_VERSION}`.

✅ Secrets are managed by the setup wizard.

✅ `api` and `check` share the same application image.