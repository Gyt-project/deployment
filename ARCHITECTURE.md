# GYT — Architecture & Services

GYT is a self-hosted Git platform built as a set of small, independent services that each do one thing. The services communicate through well-defined contracts (gRPC, Redis pub/sub, HTTP/WebSocket) and share only the infrastructure they actually need.

---

## The Big Picture

```
  Browser
    │
    │  HTTP / WebSocket
    ▼
┌──────────────┐        gRPC         ┌───────────────┐
│   Frontend   │ ─────────────────── │    Gateway    │
│  (Next.js)   │                     │  (GraphQL)    │
└──────────────┘                     └───────┬───────┘
    │                                        │ gRPC
    │  WebSocket / SSE                       ▼
    │                              ┌───────────────────┐
    │                              │      Backend      │
    │                              │  (gRPC API server)│
    ▼                              └───┬───────────┬───┘
┌──────────────┐  gRPC                 │           │
│     Live     │ ──────────────────────┘           │ gRPC
│ (WS + SSE)   │                                   ▼
└──────┬───────┘                      ┌────────────────────┐
       │                              │     soft-serve     │
       │  Redis pub/sub               │   (Git server)     │
       ▼                              └────────────────────┘
┌──────────────┐
│    Redis     │
└──────────────┘

     ▲  (Backend + Live both read/write here)
     │
┌──────────────┐
│  PostgreSQL  │
└──────────────┘
```

---

## Services

### soft-serve — Git server

This is the actual repository storage layer. It speaks SSH (port 23231), HTTP (port 23232), and the raw Git daemon protocol (port 9418). It is a fork of Charm's [soft-serve](https://github.com/charmbracelet/soft-serve) adapted for this project.

The backend uses a gRPC client to talk to soft-serve whenever it needs to create repositories, check access, or perform other git-management operations. No other service touches soft-serve directly.

### backend — gRPC API server

The core of the system. It owns the database schema and is the only service that runs migrations. Every meaningful operation — users, repositories, issues, pull requests, organizations, webhooks, branch protections — is implemented here as a gRPC method.

It connects to:
- **PostgreSQL** — primary data store
- **Redis** — result caching (reduces repeated calls to the DB and to soft-serve)
- **soft-serve** — git repository operations over gRPC

No HTTP, no GraphQL. Its only public interface is the gRPC contract defined in `backend_api.proto`.

### gateway — GraphQL API gateway

A thin HTTP server that translates incoming GraphQL queries and mutations into gRPC calls against the backend. It also handles WebSocket connections for real-time repository and pull-request events, forwarding them to the event hub that the backend publishes onto.

JWT authentication is validated here before any gRPC call is forwarded. The gateway holds no state of its own — it is completely stateless and can be scaled horizontally.

It connects to:
- **backend** — via gRPC

Exposed on port **8080**.

### live — Real-time collaboration server

Handles the WebSocket and SSE connections used during live pull-request reviews. When multiple contributors look at the same PR simultaneously, this service synchronises their cursors, comments, and review events in real time.

It has its own HTTP surface (`/live/*`) and talks to Redis pub/sub to fan events out across any number of instances. It also calls the backend over gRPC to validate sessions and pull PR metadata.

It connects to:
- **PostgreSQL** — stores live session state (sessions, participants, chat messages, review events)
- **Redis** — pub/sub for real-time broadcast between instances
- **backend** — via gRPC for PR metadata and auth

Exposed on port **8090**.

### frontend — Next.js application

The browser-facing layer. It proxies `/graphql` requests to the gateway and `/live/*` requests to the live server, so the browser only ever talks to a single origin. Apollo Client handles GraphQL data fetching and caching on the client side.

Exposed on port **3000**.

---

## Communication patterns

| From | To | Protocol | Why |
|------|----|----------|-----|
| Frontend | Gateway | GraphQL over HTTP | Typed query/mutation interface for UI data |
| Frontend | Gateway | WebSocket | PR/repo event subscriptions |
| Frontend | Live | WebSocket / SSE | Real-time review collaboration |
| Gateway | Backend | gRPC | Efficient binary transport; strong contract |
| Live | Backend | gRPC | Auth checks and PR metadata lookups |
| Backend | soft-serve | gRPC | Git repository management |
| Backend | Redis | go-redis | Cache reads/writes |
| Live | Redis | go-redis pub/sub | Broadcast events across live instances |
| Backend | PostgreSQL | GORM (postgres driver) | Primary data persistence |
| Live | PostgreSQL | GORM (postgres driver) | Live session persistence |

---

## Infrastructure

### PostgreSQL

Shared between the backend and live services. The backend owns the core schema (users, repos, issues, PRs, etc.) and runs those migrations on startup. The live service adds its own tables (live sessions, participants, chat, review events) on top.

### Redis

Also shared, but used differently by each consumer:
- **backend** uses it as a read-through cache to avoid hammering the DB and soft-serve on repeated queries.
- **live** uses both the cache layer and the pub/sub API so that review events are broadcast to all connected WebSocket/SSE clients, even if the live service is running as multiple instances.

---

## Running everything

```bash
# Start all services
docker compose up --build

# Or bring up just the infrastructure first
docker compose up postgres redis soft-serve -d

# Then the application services
docker compose up backend gateway live frontend
```

Environment variables can be set in a `.env` file at the project root. See `backend-api/example.env` for all available options.

```
DB_USER=admin
DB_PASSWORD=secret
DB_NAME=mydatabase
JWT_SECRET=change-me
REDIS_PASSWORD=
ENV=development
CORS_ORIGIN=http://localhost:3000
SOFT_SERVE_INITIAL_ADMIN_KEYS=
```

### Port map

| Service | Port | Protocol |
|---------|------|----------|
| Frontend | 3000 | HTTP |
| Gateway | 8080 | HTTP / WebSocket |
| Live | 8090 | HTTP / WebSocket / SSE |
| Backend | 50051 | gRPC |
| soft-serve SSH | 23231 | SSH |
| soft-serve HTTP | 23232 | HTTP |
| soft-serve Stats | 23233 | HTTP |
| soft-serve Git | 9418 | Git daemon |
| PostgreSQL | 5432 | TCP |
| Redis | 6379 | TCP |

---

## Startup order

Docker Compose health checks enforce the following sequence:

```
postgres ──┐
           ├──► backend ──► gateway ──► frontend
redis ─────┘         │
                     └──► live ──────► frontend
soft-serve ──────────┘
```

The backend will retry the soft-serve health check up to five times before giving up, so a slow container start is not a problem.
