# 🔧 Setup Directory

This directory contains setup helpers, templates, and the setup wizard for Swarm Statechecker deployment.

<br>

## Table of Contents

1. [📖 Overview](#overview)
2. [🧑‍💻 Usage](#usage)
3. [🔐 Secrets](#secrets)
4. [🚀 Summary](#summary)

<br>

# 📖 Overview

The authoritative Bash setup wizard helps you:

- Create required Docker secrets
- Create/update `.env`
- Deploy the swarm stack

## 📁 Structure

```
setup/
├── .env.template          # Base environment template
├── modules/               # Bash helper scripts
│   ├── docker_helpers.sh
│   └── menu_handlers.sh
└── README.md
```

## 🚀 Quick Start

# 🧑‍💻 Usage

Run the setup wizard from the repository root:

```bash
./quick-start.sh
```

## 📝 Configuration

The setup wizard will guide you through:
1. Creating required Docker secrets
2. Setting up environment configuration
3. Deploying the stack

## 🔐 Required Secrets

# 🔐 Secrets

Before deploying, create these secrets:

```bash
# API Authentication Token
echo "YOUR_AUTH_TOKEN" | docker secret create STATECHECKER_SERVER_AUTHENTICATION_TOKEN -

# Database passwords
echo "YOUR_DB_ROOT_PW" | docker secret create STATECHECKER_SERVER_DB_ROOT_USER_PW -
echo "YOUR_DB_USER_PW" | docker secret create STATECHECKER_SERVER_DB_USER_PW -

# Telegram (optional)
echo "YOUR_BOT_TOKEN" | docker secret create STATECHECKER_SERVER_TELEGRAM_SENDER_BOT_TOKEN -

# Email (optional)
echo "YOUR_EMAIL_PW" | docker secret create STATECHECKER_SERVER_EMAIL_SENDER_PASSWORD -

# Google Drive (optional)
echo '{"type":"service_account",...}' | docker secret create STATECHECKER_SERVER_GOOGLE_DRIVE_SERVICE_ACCOUNT_JSON -
```

## 🌐 Services

The stack deploys:
- **api** - FastAPI REST API service
- **check** - Periodic checker for websites/tools/backups
- **db** - MySQL 8.4 database
- **db-migration** - Database migration runner
- **phpmyadmin** - Database admin UI (optional, controlled by PHPMYADMIN_REPLICAS)

The API receives the Telegram bot secret and the same error/info chat IDs as
the checker so authenticated administrators can send a test notification from
the Statechecker web UI. The secret is never returned to the browser.

## 🗄️ Database initialization

The DB init SQL is mounted from:

- `${DATA_ROOT}/install/database/state_checker.sql`

MySQL only runs init SQL when `${DATA_ROOT}/db_data` is empty.

<br>

# 🚀 Summary

✅ Run the setup wizard from the repo root with `./quick-start.sh`.

✅ Required secrets must exist before deploying.
