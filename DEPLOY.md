# Deploying GYT locally (development)

This guide gets the full stack running on your machine without SSL or a reverse proxy. Every service binds directly to a localhost port so you can hit each one individually with a browser, Postman, `grpcurl`, `redis-cli`, or `psql`.

---

## Prerequisites

| Tool | Minimum version | Check |
|------|----------------|-------|
| Docker Desktop (or Docker Engine + Compose v2) | Docker 24, Compose 2.20 | `docker compose version` |
| Git | any recent | `git --version` |
| `openssl` | any | `openssl version` — only needed if you want to inspect certs |

Everything else (Go, Node, PostgreSQL, Redis) runs inside containers — nothing needs to be installed on the host.

---

## 1. Clone the repository

```bash
git clone <repo-url> gyt
cd gyt
```

---

## 2. Create your local `.env` file

```bash
cp .env.example .env
```

Your `.env` should look exactly like this for local development — copy it as-is and it will work without any changes:

```dotenv
# ── Public URL ────────────────────────────────────────────────────────────────
# In dev the frontend is accessed directly on port 3000, no SSL.
PUBLIC_URL=http://localhost:3000

# ── Database ──────────────────────────────────────────────────────────────────
DB_USER=gyt
DB_PASSWORD=gytdevpassword
DB_NAME=gytdb

# ── Redis ─────────────────────────────────────────────────────────────────────
REDIS_PASSWORD=gytredisdev

# ── JWT ───────────────────────────────────────────────────────────────────────
JWT_SECRET=dev-jwt-secret-change-me-in-production-32c

# ── HAProxy ───────────────────────────────────────────────────────────────────
# Not used in dev (HAProxy is disabled by the override), but the variable must
# exist or Docker Compose will refuse to start.
HAPROXY_STATS_PASSWORD=devstats

# ── soft-serve ────────────────────────────────────────────────────────────────
# Optional: paste your SSH public key here to get admin access on first boot.
# Example: SOFT_SERVE_INITIAL_ADMIN_KEYS="ssh-ed25519 AAAA... you@host"
SOFT_SERVE_INITIAL_ADMIN_KEYS=
```

> `PUBLIC_URL` is baked into the Next.js browser bundle at image build time. If you change it after the first build, run `docker compose build frontend` to rebuild.

---

## 3. Start everything

Docker Compose automatically merges `docker-compose.override.yml` on top of the base file when both exist in the same directory, so you do not need to specify any `-f` flags.

```bash
docker compose up --build
```

The first build takes a few minutes (Go and Node dependencies are downloaded and compiled). Subsequent starts are fast.

To run in the background:

```bash
docker compose up --build -d
docker compose logs -f   # tail logs after
```

---

## 4. Wait for the health cascade

The services start in dependency order and each one waits for its dependencies to pass their health checks before it begins. The full sequence is:

```
postgres ──┐
           ├──► backend ──► gateway ──► frontend
redis ─────┘         │
                     └──► live
soft-serve ──────────┘
```

You can watch the status live:

```bash
docker compose ps
```

All services should reach `running (healthy)` within about 60 seconds on the first cold start.

---

## 5. Open the app

| URL | What it is |
|-----|-----------|
| `http://localhost:3000` | Frontend (Next.js) |
| `http://localhost:8080/playground` | GraphQL Playground |
| `http://localhost:8080/graphql` | GraphQL endpoint |
| `http://localhost:8090/health` | Live API health check |
| `http://localhost:23232` | soft-serve web UI |

---

## 6. Useful commands during development

**Rebuild a single service after a code change:**
```bash
docker compose up --build gateway
```

**Tail logs for a specific service:**
```bash
docker compose logs -f backend
docker compose logs -f live
```

**Open a PostgreSQL shell:**
```bash
docker compose exec postgres psql -U gyt -d gytdb
```

**Open a Redis shell:**
```bash
docker compose exec redis redis-cli -a devredis
```

**Call the gRPC backend directly (requires `grpcurl`):**
```bash
grpcurl -plaintext localhost:50051 list
```

**Stop everything (keeps volumes):**
```bash
docker compose down
```

**Stop everything and wipe all data (clean slate):**
```bash
docker compose down -v
```

---

## 7. Git operations via soft-serve (SSH)

soft-serve listens on SSH port `23231`. To clone a repository:

```bash
git clone ssh://localhost:23231/<repo-name>.git
```

To add your SSH key as an admin (if you left `SOFT_SERVE_INITIAL_ADMIN_KEYS` empty):

```bash
docker compose exec soft-serve soft admin user create --admin --key "$(cat ~/.ssh/id_ed25519.pub)" yourusername
```

---

## Port reference

| Port | Service | Protocol |
|------|---------|----------|
| 3000 | Frontend | HTTP |
| 8080 | Gateway (GraphQL) | HTTP / WebSocket |
| 8090 | Live API | HTTP / WebSocket / SSE |
| 50051 | Backend | gRPC |
| 23231 | soft-serve | SSH |
| 23232 | soft-serve | HTTP |
| 23233 | soft-serve | Stats HTTP |
| 5432 | PostgreSQL | TCP |
| 6379 | Redis | TCP |

---

## Differences from production

| | Development | Production |
|-|------------|-----------|
| Entry point | Direct host ports | HAProxy `:80` / `:443` |
| SSL | None | TLS 1.2+ terminated at HAProxy |
| GraphQL Playground | Enabled | Disabled (unless `ENV=development`) |
| Internal ports | Exposed on host | Not exposed — internal network only |
| Container restart policy | `unless-stopped` | `always` |
| `ENV` variable | `development` | `production` |
