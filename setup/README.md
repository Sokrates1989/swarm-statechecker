# 🔧 Setup Directory

This directory contains setup helpers, templates, and the setup wizard for Swarm Statechecker deployment.

## 📁 Structure

```
setup/
├── .env.template          # Base environment template
├── modules/               # Helper scripts (bash + PowerShell)
│   ├── docker_helpers.sh/.ps1
│   └── menu_handlers.sh/.ps1
└── README.md
```

## 🚀 Quick Start

Run the setup wizard from the repository root:

```bash
# Linux/Mac
./quick-start.sh

# Windows (PowerShell)
.\quick-start.ps1
```

## 📝 Configuration

The setup wizard will guide you through:
1. Creating required Docker secrets
2. Setting up environment configuration
3. Deploying the stack

## 🔐 Required Secrets

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
