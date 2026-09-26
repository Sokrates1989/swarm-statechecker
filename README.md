# 🚀 swarm-statechecker README

Docker Swarm deployment tooling for the **statechecker** application stack.

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

The Bash setup wizard generates `swarm-stack.yml` from tracked templates and
deploys the result after read-only configuration, secret, network, and render
validation.

Services:

- **api**: FastAPI REST API
- **check**: periodic checker
- **db**: MySQL database
- **db-migration**: one-shot database migration service
- **web**: Nginx web interface
- **phpmyadmin**: optional DB UI

The stack keeps `${IMAGE_NAME}:${IMAGE_VERSION}` (from `.env`) for both `api`
and `check`. During a normal deploy, the CLI pulls the configured API/CHECK
and Web tags, resolves one digest for each repository, and renders those
digest references into the stack. The `.env` file keeps readable version tags.

<br>
<br>

# 🧑‍💻 Usage

```bash
# Run the authoritative Bash setup and management CLI.
./quick-start.sh
```

The deployment overview checks the current `main` checkout against `origin`.
Press `r` to refresh that repository state or `u` to apply a clean,
fast-forward-only update and restart the menu. Self-update is blocked when the
checkout has local changes, is ahead/diverged, uses an unexpected origin or
branch, or cannot verify its upstream safely.

Management option `6` updates deployed image versions. Choose API/CHECK, Web,
or **both**. The paired choice asks for one explicit tag, checks that all three
Swarm services exist, pulls both images, and resolves their exact repository
digests before changing any service. It updates API, CHECK, and Web using those
digests, verifies each service spec, saves both `.env` version keys only after
successful updates, and runs readiness and health checks. If the same tag is
already configured, this choice can pin services that still use tag-only image
references. A missing or ambiguous digest stops the update before any service
change; a failure after updates begin can leave a partial rollout. Inspect the
reported service state before retrying. The menu rejects `latest`. This option
uses published images; it does not build or push. A later normal stack redeploy
resolves the configured version tags again and retains digest-pinned service
specs. It stops before service changes if a pull, digest lookup, or rendered
image check fails.

<br>
<br>

# 🛠️ Configuration / Installation / Setup

The recommended path is the guided wizard started by `./quick-start.sh`. For a
manual starting point, copy the complete template:

```bash
cp setup/.env.template .env
```

2) Edit `.env` and set:

- `STACK_NAME`
- `DATA_ROOT`
- `IMAGE_NAME`, `IMAGE_VERSION`
- `PROXY_TYPE` and either direct ports or Traefik network/domains
- `INIT_WEBSITES` for first-start database seeding (optional)

Use explicit image versions. The templates currently default to `3.0.1` and
the deployment preflight rejects mutable `latest` tags.

Website checks default to a five-minute interval. This keeps peer outage
detection reasonably fast without reacting as aggressively to short network
interruptions as a two-minute interval.

<br>
<br>

# 🔐 Secrets

Required secrets:

- `STATECHECKER_SERVER_AUTHENTICATION_TOKEN`
- `STATECHECKER_SERVER_DB_ROOT_USER_PW`
- `STATECHECKER_SERVER_DB_USER_PW`
- `STATECHECKER_SERVER_KEYCLOAK_CLIENT_SECRET`

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
- `Health check`

Deployment renders `swarm-stack.yml` with Docker Compose before running
`docker stack deploy`. The preflight fails when required configuration,
secrets, generated services, or the selected Traefik network are missing. It
also pulls both application images and verifies the rendered API, CHECK, and
Web digest references before changing services.

For peer monitoring, health checks, and emergency API restoration, see
[Always-up operations](docs/always-up-operations.md).

The health command fails when persistent services are not converged, active
tasks are rejected or failed, the migration task failed, or the public API/web
endpoints cannot be reached. It is also available non-interactively:

```bash
./quick-start.sh --health
```

## Local validation

From the repository root:

```bash
python -B -m unittest discover -s tests -v
./quick-start.sh --smoke-test
```

The unit tests do not contact Docker. The smoke test checks Bash syntax and
renders the no-proxy, direct-TLS, and proxy-TLS stacks with Docker Compose. It
does not contact Swarm or deploy anything.

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

✅ Swarm deployment uses explicitly versioned application images.

✅ Secrets are managed by the setup wizard.

✅ `api` and `check` share the same application image.

✅ `quick-start.sh` is the authoritative Linux deployment CLI.
