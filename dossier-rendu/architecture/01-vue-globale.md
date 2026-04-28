# Architecture globale — GYT

## Vue d'ensemble (C4 niveau 2 — Container)

```mermaid
graph TB
    subgraph Client["Navigateur (Client)"]
        B([Utilisateur])
    end

    subgraph Proxy["Couche proxy"]
        HAP["HAProxy<br/>SSL termination<br/>:80 / :443"]
    end

    subgraph App["Couche applicative"]
        FE["Frontend<br/>Next.js / Apollo Client<br/>:3000"]
        GW["Gateway<br/>GraphQL + WebSocket<br/>:8080"]
        LV["Live<br/>WS / SSE review temps réel<br/>:8090"]
    end

    subgraph Core["Cœur métier"]
        BE["Backend<br/>gRPC API server<br/>:50051"]
        SS["soft-serve<br/>Git server<br/>SSH :23231  HTTP :23232"]
    end

    subgraph Infra["Infrastructure"]
        PG[("PostgreSQL<br/>:5432")]
        RD[("Redis<br/>:6379")]
    end

    B -->|"HTTP / WebSocket"| HAP
    HAP -->|"/* → Next.js"| FE
    HAP -->|"/graphql /ws/*"| GW
    HAP -->|"/live/*"| LV
    HAP -->|"TCP passthrough SSH"| SS

    FE -->|"GraphQL over HTTP"| GW
    FE -->|"WebSocket"| LV

    GW -->|"gRPC"| BE
    LV -->|"gRPC (auth + PR metadata)"| BE

    BE -->|"gRPC"| SS
    BE -->|"go-redis (cache)"| RD
    BE -->|"GORM"| PG

    LV -->|"go-redis pub/sub"| RD
    LV -->|"GORM (sessions live)"| PG
```

---

## Séparation des responsabilités

| Service    | Ce qu'il fait                                              | Ce qu'il ne fait PAS                              |
|------------|------------------------------------------------------------|---------------------------------------------------|
| `frontend` | Rendu UI, routing, Apollo cache                            | Aucune logique métier, aucun accès DB direct      |
| `gateway`  | Traduction GraphQL ↔ gRPC, validation JWT                  | Aucun état, aucun accès DB                        |
| `live`     | Synchronisation curseurs/commentaires en temps réel        | Aucune opération git                              |
| `backend`  | Toute la logique métier (users, repos, PRs, issues, orgs)  | Pas d'HTTP public, pas de WebSocket               |
| `soft-serve` | Stockage et service des dépôts git                       | Pas de logique applicative                        |

---

## Ordre de démarrage (health checks Docker Compose)

```mermaid
graph LR
    PG[(postgres)] --> BE[backend]
    RD[(redis)]    --> BE
    SS[soft-serve] --> BE
    BE --> GW[gateway]
    BE --> LV[live]
    GW --> FE[frontend]
    LV --> FE
    FE --> HAP[haproxy]
```

Le backend réessaie la connexion à soft-serve jusqu'à 5 fois — une lenteur au démarrage du conteneur n'est pas bloquante.

---

## Tableau des protocoles

| Émetteur   | Destinataire | Protocole           | Raison                                          |
|------------|--------------|---------------------|-------------------------------------------------|
| Frontend   | Gateway      | GraphQL / HTTP      | Interface typée et flexible pour l'UI           |
| Frontend   | Gateway      | WebSocket           | Subscriptions (événements repo/PR)              |
| Frontend   | Live         | WebSocket / SSE     | Collaboration review en temps réel              |
| Gateway    | Backend      | gRPC                | Transport binaire, contrat fort, perf           |
| Live       | Backend      | gRPC                | Vérification auth et métadonnées PR             |
| Backend    | soft-serve   | gRPC                | Gestion des dépôts git                          |
| Backend    | Redis        | go-redis            | Cache lectures DB et soft-serve                 |
| Live       | Redis        | go-redis pub/sub    | Diffusion événements multi-instances            |
| Backend    | PostgreSQL   | GORM                | Persistance primaire                            |
| Live       | PostgreSQL   | GORM                | Sessions live, participants, messages           |
