# Environment Templates

This directory contains modular environment configuration templates that are
assembled by the setup wizard to create the final `.env` file.

## Templates

- **`.env.base.template`** - Core settings applicable to all deployments
- **`.env.proxy-traefik.template`** - Traefik reverse proxy configuration  
- **`.env.proxy-none.template`** - Direct port exposure (no proxy)

## How It Works

The setup wizard combines these templates based on your selections:

1. Starts with `.env.base.template`
2. Appends proxy configuration based on your choice

The resulting `.env` file is created in the project root.

## SSL Termination Modes

When using Traefik, you can choose between:

- **direct** - Traefik handles SSL/TLS termination directly (uses Let's Encrypt)
- **proxy** - Traefik runs behind another TLS terminator (e.g., Nginx Proxy Manager)

This affects the Traefik labels in the generated `swarm-stack.yml`.
