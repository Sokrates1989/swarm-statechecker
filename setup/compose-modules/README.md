# Compose Modules

This directory contains modular Docker Compose service templates that are
assembled by the setup wizard to create the final `swarm-stack.yml` file.

## Service Templates

- **`base.yml`** - Services header
- **`api.template.yml`** - Statechecker API service
- **`check.template.yml`** - Background check service
- **`db.template.yml`** - MySQL database service
- **`db-migration.template.yml`** - One-shot migration service
- **`phpmyadmin.template.yml`** - phpMyAdmin for DB management
- **`web.template.yml`** - Nginx web frontend
- **`footer.yml`** - Networks and secrets declarations

## Snippets

The `snippets/` directory contains partial YAML fragments that are injected
into templates based on deployment configuration:

### Proxy Labels (Traefik)
- `proxy-traefik-direct-ssl.labels.yml` - API labels for Traefik with direct SSL
- `proxy-traefik-proxy-ssl.labels.yml` - API labels for Traefik behind TLS terminator
- `proxy-traefik-direct-ssl-web.labels.yml` - Web labels for direct SSL
- `proxy-traefik-proxy-ssl-web.labels.yml` - Web labels behind TLS terminator
- `proxy-traefik-direct-ssl-pma.labels.yml` - phpMyAdmin labels for direct SSL
- `proxy-traefik-proxy-ssl-pma.labels.yml` - phpMyAdmin labels behind TLS terminator

### Proxy Ports (No Proxy)
- `proxy-none.ports.yml` - API port exposure
- `proxy-none-web.ports.yml` - Web port exposure
- `proxy-none-pma.ports.yml` - phpMyAdmin port exposure

### Network Snippets
- `proxy-traefik.network.yml` - Traefik network for services
- `traefik-network.footer.yml` - External Traefik network declaration

## Placeholders

Templates use these placeholders that are replaced during build:

- `###PROXY_NETWORK###` - Traefik network attachment
- `###PROXY_LABELS###` - Traefik router/service labels
- `###PROXY_PORTS###` - Direct port exposure
- `###PROXY_NETWORK_WEB###` - Web service Traefik network
- `###PROXY_LABELS_WEB###` - Web service Traefik labels
- `###PROXY_PORTS_WEB###` - Web service direct ports
- `###PROXY_NETWORK_PMA###` - phpMyAdmin Traefik network
- `###PROXY_LABELS_PMA###` - phpMyAdmin Traefik labels
- `###PROXY_PORTS_PMA###` - phpMyAdmin direct ports
- `###TRAEFIK_NETWORK###` - External Traefik network in footer

## SSL Modes

When using Traefik, two SSL modes are supported:

1. **direct** - Traefik terminates SSL/TLS directly using Let's Encrypt
   - Uses `entrypoints=https` and `tls.certresolver=le`
   
2. **proxy** - Traefik runs behind another TLS terminator (e.g., Nginx Proxy Manager)
   - Uses `entrypoints=http` only
   - X-Forwarded-Proto header is set for proper HTTPS detection
