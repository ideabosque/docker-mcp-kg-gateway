# docker-mcp-kg-gateway

A [SilvaEngine Gateway](https://github.com/ideabosque/silvaengine_gateway) image
exposing ONLY:

- **[mcp_daemon_engine](https://github.com/ideabosque/mcp_daemon_engine)** — MCP
  (Model Context Protocol) JSON-RPC over REST/SSE, plus a GraphQL admin surface
  (functions, modules, settings).
- **[knowledge_graph_engine](https://github.com/ideabosque/knowledge_graph_engine)**
  — GraphQL CRUD (documents, graph schemas, Neo4j instances, requests) and async
  document extraction (entity/relationship extraction into a Neo4j graph).

PostgreSQL is the metadata backend for both engines (`db_backend=postgresql` is
forced in the image — no DynamoDB option). Neo4j is the graph store required by
`knowledge_graph_engine`. Both databases can run as bundled sibling containers
or point at external instances — see [Databases](#databases) below.

Modeled on [`../docker-a2a-openclaw-gateway`](../docker-a2a-openclaw-gateway):
the engine packages are `pip install`-ed from git straight into the image (no
host source mount), so the container is fully self-contained and reproducible
from a `git clone` + `docker compose build`. All three (`silvaengine_gateway`,
`mcp_daemon_engine`, `knowledge_graph_engine`) plus `mcp_http_client` and the
shared SilvaEngine libraries are **private** ideabosque repos, so the build
clones them over SSH (see [Private repos over SSH](#private-repos-over-ssh)
below, required before the first build) — mirrors
[`../docker-silvaengine-gateway`](../docker-silvaengine-gateway)'s approach.

## Quick start

```bash
cp .env.example .env
# Edit .env: set JWT_SECRET_KEY, ADMIN_PASSWORD, POSTGRES_PASSWORD /
# PG_PASSWORD, NEO4J_AUTH / neo4j_password, and openai_api_key (KGE extraction
# uses an LLM). Defaults bring up bundled Postgres + Neo4j.
# Set up ./.ssh first — see "Private repos over SSH" below.
docker compose up --build -d
make health
```

## Private repos over SSH

The Dockerfile clones `silvaengine_gateway`, `mcp_daemon_engine`,
`knowledge_graph_engine`, `mcp_http_client`, and the shared
`silvaengine_*` libraries over `git+ssh://git@github.com/...`. Before the
first `docker compose build`:

1. Drop a deploy key with read access to those repos into `./.ssh/` (e.g.
   `./.ssh/id_rsa` + `./.ssh/id_rsa.pub`). If it's your only key there,
   nothing else is needed — ssh finds it automatically.
2. If you need a specific (non-default-named) key, or your own `~/.ssh`
   already has a conflicting `github.com` entry, copy
   `.ssh/config.example` to `.ssh/config` and point `IdentityFile` at your
   key's filename.
3. `docker compose build` (or `docker build .`) — the Dockerfile copies
   `./.ssh` into the image, `chmod`s it, and runs `ssh-keyscan github.com`
   to trust the host before cloning.

`.ssh/` is gitignored except `.gitkeep` and `config.example` — never commit
a real private key. The key material ends up baked into the built image (not
just the build cache), matching `../docker-silvaengine-gateway`'s tradeoff:
treat the image itself as something with SSH access to those repos (don't
push it to a public registry).

## Architecture

```
                     ┌───────────────────────────┐
  client ──HTTPS──▶  │   mcp-kg-gateway (:8766)  │
                     │  FastAPI + supervisord     │
                     │  silvaengine_gateway        │
                     │   ├─ mcp_daemon_engine      │
                     │   └─ knowledge_graph_engine │
                     └──────────┬──────────┬───────┘
                                │          │
                     bolt://neo4j:7687   postgresql://postgres:5432
                                │          │
                     ┌──────────▼───┐  ┌───▼──────────┐
                     │    neo4j     │  │   postgres   │
                     │ (graph store)│  │  (metadata)  │
                     └──────────────┘  └──────────────┘
```

- **mcp-kg-gateway** — always on. A single FastAPI/uvicorn process (run under
  supervisord) serving JSON-RPC, GraphQL, REST and SSE for both engines on one
  port.
- **postgres** — optional bundled service (`COMPOSE_PROFILES=postgres`).
  Stores KGE documents/graph-schemas/Neo4j-instance-registry/requests and MCP
  functions/modules/settings/function-calls. Tables auto-create on startup
  (`initialize_tables=1`).
- **neo4j** — optional bundled service (`COMPOSE_PROFILES=neo4j`). The actual
  knowledge graph store that KGE's GraphRAG / text2cypher / extraction
  pipeline reads and writes.

## Databases

Both databases can be bundled or external, independently:

| Backend | Bundled (default) | External |
| --- | --- | --- |
| PostgreSQL | `COMPOSE_PROFILES=postgres`, `PG_HOST=postgres` | drop `postgres` from `COMPOSE_PROFILES`, set `PG_HOST=host.docker.internal` (or a remote host) |
| Neo4j | `COMPOSE_PROFILES=neo4j`, `neo4j_uri=bolt://neo4j:7687` | drop `neo4j` from `COMPOSE_PROFILES`, set `neo4j_uri=bolt://host.docker.internal:7687` |

`.env.example` ships with `COMPOSE_PROFILES=postgres,neo4j` — both bundled by
default. `NEO4J_AUTH` must match `neo4j_username`/`neo4j_password`;
`POSTGRES_USER`/`POSTGRES_PASSWORD`/`POSTGRES_DB` must match
`PG_USER`/`PG_PASSWORD`/`PG_DB`.

The default **host-side** ports (`POSTGRES_PORT=5433`, `NEO4J_BROWSER_PORT=7475`,
`NEO4J_BOLT_PORT=7688`) are deliberately non-standard: `../docker-silvaengine-gateway`
bundles Postgres/Neo4j on the standard 5432/7474/7687, and both stacks are
meant to be able to run at the same time without a port collision. These only
affect host access (`localhost:5433`, etc.) — `PG_PORT`/`neo4j_uri` (used
inside the docker network to reach the bundled `postgres`/`neo4j` services)
stay on the databases' normal 5432/7687.

`knowledge_graph_engine` uses a configurable PostgreSQL table prefix
(`KGE_PG_TABLE_PREFIX`, default `kge_`) so it can safely share a database with
other SilvaEngine modules; `mcp_daemon_engine` uses its own literal table
names (`mcp_functions`, `mcp_modules`, `mcp_settings`, `mcp_function_calls`).

## Endpoints

All routes carry only `{endpoint_id}` in the path; the tenant partition id is
supplied via the `Part-Id` request header. The gateway builds
`partition_key = "{endpoint_id}#{Part-Id}"`.

### Knowledge Graph Engine

| Path | Method | Type | Notes |
| --- | --- | --- | --- |
| `/{endpoint_id}/knowledge_graph_graphql` | POST | GraphQL | Documents, graph schemas, Neo4j instances, requests |
| `/{endpoint_id}/extract` | POST | background | Async entity/relationship extraction |
| `/{endpoint_id}/extract/status/{task_id}` | GET | task_status | Poll an extraction job |

### MCP Daemon Engine

| Path | Method | Type | Notes |
| --- | --- | --- | --- |
| `/{endpoint_id}/mcp_daemon_graphql` | POST | GraphQL | Functions, modules, settings admin |
| `/{endpoint_id}/mcp` | POST | REST | MCP JSON-RPC 2.0 (no SSE broadcast) |
| `/{endpoint_id}/sse` | GET | SSE | Long-lived SSE connection |
| `/{endpoint_id}/sse` | POST | REST | JSON-RPC message + SSE push |
| `/{endpoint_id}/mcp_async_execute` | POST | background | Async tool execution |
| `/{endpoint_id}/mcp_async/status/{task_id}` | GET | task_status | Poll a tool-execution job |
| `/{endpoint_id}/admin/cache/refresh` | POST | REST | Refresh MCP config cache |
| `/{endpoint_id}/admin/cache` | DELETE | REST | Clear MCP config cache for a partition |
| `/{endpoint_id}/mcp_info` | GET | REST | Endpoint info |

### Gateway

| Path | Method | Notes |
| --- | --- | --- |
| `/health` | GET | Public, no auth |

## Volumes

| Host path | Container path | Purpose |
| --- | --- | --- |
| `./logs` | `/var/log/supervisor` | supervisord + gateway process logs |
| `./data` | `/app/data` | MCP tool-package staging (`FUNCT_ZIP_PATH`/`FUNCT_EXTRACT_PATH`), local user file |
| `./routes.yaml` (`GATEWAY_ROUTES_HOST_FILE`) | `/app/routes.yaml` (ro) | Route manifest — edit + restart, no rebuild |
| `./postgres_data` | `/var/lib/postgresql/data` | Bundled Postgres data dir (profile: postgres) |
| `./postgres_logs` | `/var/log/postgresql` | Bundled Postgres logs |
| `./neo4j_data/{data,logs,import,plugins}` | `/{data,logs,import,plugins}` | Bundled Neo4j data (profile: neo4j) |

## Key environment variables

See `.env.example` for the full annotated list. Highlights:

| Variable | Default | Purpose |
| --- | --- | --- |
| `CONTAINER_PORT` / `GATEWAY_PORT` | `8766` / `8765` | Host port / in-container bind port |
| `GATEWAY_ROUTES_HOST_FILE` | `./routes.yaml` | Host file mounted over `/app/routes.yaml` |
| `JWT_SECRET_KEY`, `ADMIN_USERNAME`, `ADMIN_PASSWORD` | — | Local auth provider credentials |
| `PG_HOST`, `PG_USER`, `PG_PASSWORD`, `PG_DB` | `postgres` / `silvaengine` / `silvaengine` / `silvaengine` | PostgreSQL connection |
| `KGE_PG_TABLE_PREFIX` | `kge_` | KGE's PostgreSQL table prefix |
| `neo4j_uri`, `neo4j_username`, `neo4j_password`, `neo4j_database` | `bolt://neo4j:7687` / `neo4j` / `12345abc` / `neo4j` | Neo4j connection |
| `llm_type`, `llm_name`, `openai_api_key`, `embedding_model` | `openai` / `gpt-4o` / — / `text-embedding-3-small` | LLM used by KGE extraction / text2cypher / RAG |
| `FUNCT_BUCKET_NAME`, `FUNCT_ZIP_PATH`, `FUNCT_EXTRACT_PATH` | — / `/app/data/funct_zips` / `/app/data/functs` | MCP tool-package staging |
| `COMPOSE_PROFILES` | `postgres,neo4j` | Which bundled databases to start |

Baked into the image (not overridable via `.env`, only by editing the
Dockerfile): `db_backend=postgresql`, `GATEWAY_ROUTES_CONFIG_PATH=/app/routes.yaml`.

## Makefile targets

| Target | Description |
| --- | --- |
| `make build` / `make up` / `make dev` | Build / start detached / build+start with live logs |
| `make down` / `make clean` / `make rebuild` | Stop / stop+drop volumes / clean rebuild |
| `make logs` / `make gateway-logs` | Tail all container logs / just the gateway process log |
| `make status` / `make restart` / `make shell` | supervisorctl status / restart / open a shell |
| `make health` | `curl` the public `/health` endpoint |
| `make postgres-up` / `make postgres-down` | Start/stop the bundled Postgres sibling |
| `make neo4j-up` / `make neo4j-down` | Start/stop the bundled Neo4j sibling |

## Adding more engine modules later

Two independent steps — routing registration, and making the module's code
importable — and only the second ever needs a rebuild.

**1. Register its routes** — drop a `*.yaml` file into `./addons/` (see
`addons/README.md`) with a module map (name, package, `routes:`, etc. — same
shape as `addons/knowledge_graph_engine.yaml` / `addons/mcp_daemon_engine.yaml`,
this image's own core modules, registered the identical drop-in way). At
container startup this gets merged into `routes.yaml`'s permanent
`!include data/_addons_generated.yaml` line, so `routes.yaml` itself never
needs editing. A module that fails to import is logged and skipped, not
fatal — other modules keep working regardless. Restart the container
(`make restart`) — no rebuild.

**2. Make the module importable** — either:
- **Baked in** (production): add its git+ssh line to
  `requirements-modules.txt` (installed `--no-deps`) and its third-party deps
  to `requirements.txt`, then `docker compose build`; or
- **Local source, no rebuild** (dev): point `PYTHONPATH` in `.env` at its repo
  root under `/app/src` (see the "Local source overrides" section in
  `.env.example`) — its own third-party deps still need a one-time addition
  to `requirements.txt` + rebuild.

See `silvaengine_gateway`'s own packaged `routes.yaml` / `module_routes/*.yaml`
for reference fragments per engine (RFQ, A2A, AI agent core, ...).
