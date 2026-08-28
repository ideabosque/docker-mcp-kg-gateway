# =============================================================================
# docker-mcp-kg-gateway — image
# =============================================================================
# A slim Python 3.12 image that runs the SilvaEngine Gateway with ONLY the
# mcp_daemon_engine and knowledge_graph_engine modules registered, exposing
# MCP (JSON-RPC over REST/SSE) and the Knowledge Graph GraphQL + extraction
# surface. PostgreSQL is the metadata backend for both engines; Neo4j is the
# graph store for knowledge_graph_engine.
#
# All three packages (silvaengine_gateway, mcp_daemon_engine,
# knowledge_graph_engine) are pip-installed from git INTO the image over SSH
# (mirrors ../docker-silvaengine-gateway) — needed because these are PRIVATE
# ideabosque repos. Configuration is entirely env-driven at runtime via .env
# (see .env.example).
#
# Drop a deploy key (with read access to the ideabosque repos below) into
# ./.ssh before building — see README "Private repos over SSH". The key
# material itself is never baked into any image layer beyond this build
# stage's filesystem; this is a single-stage image, so treat the built image
# like you would any host with SSH access to those repos (don't publish it
# to a public registry).
# =============================================================================

FROM python:3.12-slim

WORKDIR /app

# ── System deps + uv ──────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y \
    supervisor \
    curl \
    openssh-client \
    git \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && rm -rf /var/lib/apt/lists/*

# SSH setup — the gateway pulls private ideabosque repos over git+ssh.
# Drop a deploy key into ./.ssh before building (see README).
ADD .ssh /root/.ssh
RUN chmod 700 /root/.ssh && \
    (chmod 600 /root/.ssh/* 2>/dev/null || true) && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts

ENV PATH="/root/.local/bin:$PATH"

# ── Python dependencies ──────────────────────────────────────────────────────
# requirements.txt installs the third-party deps AND the shared SilvaEngine
# libraries (silvaengine_utility, silvaengine_dynamodb_base, ...) from git over
# SSH. requirements-modules.txt then installs silvaengine_gateway,
# mcp_daemon_engine and knowledge_graph_engine --no-deps: their metadata
# declares engines / bare names not on PyPI (and intentionally absent from
# this image, e.g. rfq_engine, ai_agent_core_engine); their real deps are
# already satisfied by requirements.txt.
COPY requirements.txt requirements-modules.txt ./

RUN uv venv /opt/venv && \
    uv pip install --python /opt/venv/bin/python -r requirements.txt && \
    uv pip install --python /opt/venv/bin/python --no-deps -r requirements-modules.txt

ENV PATH="/opt/venv/bin:$PATH"

# ── PostgreSQL is the metadata backend for both engines ─────────────────────
# Both mcp_daemon_engine.Config and knowledge_graph_engine.Config default
# DB_BACKEND to "dynamodb"; we force "postgresql" here so the gateway always
# wires the SQLAlchemy session even if .env omits db_backend. Override only if
# you know why (Neo4j is unaffected — it is always required by KGE).
ENV db_backend=postgresql

# ── Route manifest (all modules are drop-in addons) ──────────────────────────
# The packaged gateway ships a routes.yaml registering every engine module
# (KGE, RFQ, MCP, A2A, ...). This image's routes.yaml is just a loader: one
# permanent !include line that pulls in whatever's under ./addons/ — merged
# at container startup by docker-entrypoint.sh (see
# scripts/merge_addon_routes.py and addons/README.md). This image's two core
# modules (knowledge_graph_engine, mcp_daemon_engine) are themselves addon
# files (addons/knowledge_graph_engine.yaml, addons/mcp_daemon_engine.yaml)
# — NOT baked into the image (addons/ is bind-mounted only, see
# docker-compose.yml). GATEWAY_ROUTES_CONFIG_PATH points at routes.yaml
# below. Running this image without the compose bind mounts (routes.yaml +
# addons/) registers ZERO modules — this image is meant to run via
# docker-compose, not standalone `docker run`.
COPY routes.yaml /app/routes.yaml
COPY scripts/merge_addon_routes.py /app/scripts/merge_addon_routes.py

# ── Supervisor ───────────────────────────────────────────────────────────────
RUN mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Entrypoint runs the addon merge step, then execs supervisord. This is the
# ONLY place that decides how the container starts — do not add a
# `command:` override in docker-compose.yml, or it silently bypasses this.
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# ── Non-root user ────────────────────────────────────────────────────────────
RUN useradd -m -u 1000 gateway && \
    mkdir -p /app/data && \
    chown -R gateway:gateway /app

EXPOSE 8000

# Default route manifest is the MCP+KGE one baked above. Override via .env.
ENV GATEWAY_ROUTES_CONFIG_PATH=/app/routes.yaml

# Entrypoint merges ./addons/ into routes.yaml's !include target, then starts
# supervisor as root (which drops privileges for the gateway process).
CMD ["/usr/local/bin/docker-entrypoint.sh"]
