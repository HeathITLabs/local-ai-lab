# Local AI Stack - Self-Hosted AI Hub

A Docker Compose stack that bundles the local-first tools needed to build and ship AI workflows on your own machine. It includes orchestration (n8n), agent builders (Flowise, Open WebUI), vector search (Qdrant), graph storage (Neo4j), and supporting services (Valkey/Redis-compatible, Caddy, SearXNG). Postgres and Langfuse have been removed; n8n now runs on SQLite by default.

## What's included
- n8n for low-code automation
- Ollama for local LLMs (CPU, NVIDIA, and AMD ROCm profiles)
- Open WebUI for chat with local models
- Flowise for visual agent building
- Qdrant for vector search
- Neo4j for graph workloads
- Valkey (Redis-compatible), Caddy reverse proxy, and SearXNG for search

## Prerequisites
- Docker and Docker Compose
- Python 3.8+ if you want to use `start_services.py`
- ~8GB RAM minimum (more recommended for multiple services)

## Setup
1) Fill in secrets in `.env`  
   - Generate strong values for `N8N_ENCRYPTION_KEY` and `N8N_USER_MANAGEMENT_JWT_SECRET`.  
   - Optional: set hostnames for Caddy if you want TLS/virtual hosts.

2) Start the stack (uses the private/localhost binding by default):  
   ```bash
   python start_services.py --profile cpu --environment private
   ```  
   - Use `--profile gpu-nvidia` or `--profile gpu-amd` if you want GPU acceleration.  
   - `--environment public` will skip the private port-binding override file.

The helper script will:
- Ensure SearXNG has a unique secret key on first run.
- Validate the composed Docker config before starting containers.

## Access the services
- n8n: http://localhost:5678/
- Open WebUI: http://localhost:3190/
- Flowise: http://localhost:3001/
- Qdrant: http://localhost:6333/dashboard
- Neo4j: http://localhost:7474/
- SearXNG: http://localhost:8081/ (when using the private override)

## Managing the stack
- Stop everything: `docker compose -p localai down`
- Update images: `docker compose -p localai pull && docker compose -p localai up -d`
- Switch profiles: `docker compose -p localai --profile gpu-nvidia up -d`

## Data persistence
Key volumes: `n8n_storage`, `ollama_storage`, `qdrant_storage`, `open-webui`, `flowise`, `caddy-data`, `caddy-config`, `valkey-data`.

## Troubleshooting
- If ports are in use, stop existing containers with `docker compose -p localai down`.
- Regenerate secrets if authentication fails (n8n).  
- Check logs: `docker compose -p localai logs [service-name]`.
