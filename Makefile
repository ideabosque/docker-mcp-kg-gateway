.PHONY: build up down logs gateway-logs status restart shell health clean rebuild dev \
        postgres-up postgres-down neo4j-up neo4j-down

# Overridable from the environment, e.g.
#   GATEWAY_CONTAINER_NAME=my-gateway make shell
#   CONTAINER_PORT=9000 make health
# Note: make does NOT read .env — export the variable if you changed it there.
GATEWAY_CONTAINER_NAME ?= mcp-kg-gateway
CONTAINER_PORT          ?= 8766

# Build the Docker image
build:
	docker compose build

# Start the gateway in the background
up:
	docker compose up -d

# Build and start with live logs (foreground)
dev:
	docker compose up --build

# Stop and remove containers
down:
	docker compose down

# Tail combined logs (gateway + optional postgres/neo4j)
logs:
	docker compose logs -f

# Tail just the gateway process log inside the container
gateway-logs:
	docker exec $(GATEWAY_CONTAINER_NAME) supervisorctl tail -f silvaengine-gateway

# Supervisor process status
status:
	docker exec $(GATEWAY_CONTAINER_NAME) supervisorctl status

# Restart the gateway process without rebuilding the container
restart:
	docker exec $(GATEWAY_CONTAINER_NAME) supervisorctl restart silvaengine-gateway

# Open a shell in the gateway container
shell:
	docker exec -it $(GATEWAY_CONTAINER_NAME) /bin/bash

# Hit the public health endpoint
health:
	curl -f http://localhost:$(CONTAINER_PORT)/health

# Stop containers and drop volumes + dangling images
clean:
	docker compose down -v
	docker image prune -f

# Full rebuild from scratch
rebuild: clean build up

# Bring up the bundled PostgreSQL sibling service (profile: postgres)
postgres-up:
	docker compose --profile postgres up -d postgres

# Stop the bundled PostgreSQL sibling (gateway stays up)
postgres-down:
	docker compose --profile postgres stop postgres

# Bring up the bundled Neo4j sibling service (profile: neo4j)
neo4j-up:
	docker compose --profile neo4j up -d neo4j

# Stop the bundled Neo4j sibling (gateway stays up)
neo4j-down:
	docker compose --profile neo4j stop neo4j
