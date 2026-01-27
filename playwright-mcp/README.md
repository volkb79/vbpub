# Playwright MCP Standalone Service

Standalone Playwright service with **WebSocket** and **MCP** interfaces, designed for multi-project browser automation with public access, strong authentication, and optional TLS via reverse proxy.

## Key Features

- WebSocket API for full Playwright control (recommended for tests)
- MCP server for VS Code Copilot chat
- Token authentication (required by default)
- Optional TLS via Nginx + Let’s Encrypt
- Buildx Bake build/push workflow
- CIU-ready standalone project (ships CIU defaults + compose templates)

## Quick Start

1. Copy and edit env file:

```bash
cp .env.sample .env
```

2. Set required fields:
- `ACCESS_TOKEN`
- `PUBLIC_FQDN` (for reverse proxy)
- `LETSENCRYPT_DIR` (parent directory, e.g., `/etc/letsencrypt`)

3. Start the container:

```bash
docker compose -f docker-compose.manual.yml up -d
```

4. (Optional) Start reverse proxy:

```bash
docker compose -f docker-compose.manual.yml --profile proxy up -d
```

## CIU Quick Start (Standalone)

If you prefer CIU orchestration, this repo includes standalone CIU configs:

```bash
cd playwright-mcp
ciu --generate-env -d .
ciu -d .
```

Standalone means: all CIU defaults and templates live inside this repo, so users can run
`ciu` directly after download without external configuration.

To expose direct WS/MCP/health ports without the reverse proxy, set:
`playwright_mcp.ports.expose_ws = true`, `expose_mcp = true`, or `expose_health = true`
in [ciu.defaults.toml.j2](vbpub/playwright-mcp/ciu.defaults.toml.j2).

## Endpoints

- WS (direct): `ws://HOST:WS_EXTERNAL_PORT`
- MCP (direct): `http://HOST:MCP_EXTERNAL_PORT/mcp`
- WS (TLS): `wss://PUBLIC_FQDN/ws`
- MCP (TLS): `https://PUBLIC_FQDN/mcp`
- Health: `http://HOST:HEALTH_EXTERNAL_PORT/health`
- Selftest (egress): `http://HOST:HEALTH_EXTERNAL_PORT/selftest`

When using a public FQDN, ensure `MCP_ALLOWED_HOSTS` and `MCP_ALLOWED_ORIGINS`
include the public host to satisfy MCP transport security.

## Build & Push

```bash
./build-images.sh
./push-images.sh
```

## Usage Demo

Run the demo client script:

```bash
WS_URL=ws://localhost:3000 ACCESS_TOKEN=<token> python3 usage-demo.py
```

## CLI

```bash
pwmcp ws ping --url ws://localhost:3000 --token <token>
pwmcp ws navigate --url ws://localhost:3000 --token <token> --page https://example.com
pwmcp ws screenshot --url ws://localhost:3000 --token <token> --path /screenshots/example.png
```

## Documentation

- docs/ARCHITECTURE.md
- docs/SECURITY.md
- docs/DEPLOYMENT.md
- docs/USAGE.md
- docs/GAP-ANALYSIS.md
- docs/CONFIG-EXAMPLES.md

## Notes

This project was extracted from `netcup-api-filter/tooling/playwright` and upgraded for public, multi-project use.
