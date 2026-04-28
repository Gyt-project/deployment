# GYT — Dossier de rendu

Projet de fin d'études — Plateforme Git auto-hébergée

---

## Structure

```
dossier-rendu/
└── architecture/
    ├── 01-vue-globale.md           Diagramme C4 global de l'architecture
    ├── 02-diagrammes-flux.md       Diagrammes de séquence (auth, git push, PR live)
    └── 03-choix-technologiques.md  Justification des choix techniques
```

## Résumé du projet

GYT est une plateforme Git auto-hébergée construite autour de sept services indépendants qui communiquent via des contrats bien définis (gRPC, GraphQL, Redis pub/sub). L'objectif était de reproduire les fonctionnalités essentielles d'une forge Git (repositories, issues, pull requests, review en temps réel) tout en conservant une architecture déployable avec un simple `docker compose up`.

| Service      | Rôle                                      | Port public |
|--------------|-------------------------------------------|-------------|
| `frontend`   | Interface Next.js                         | 80 / 443    |
| `gateway`    | API GraphQL (passerelle stateless)        | /graphql    |
| `live`       | Review temps réel (WebSocket / SSE)       | /live/*     |
| `backend`    | Cœur métier gRPC                          | interne     |
| `soft-serve` | Serveur Git (SSH / HTTP / Git daemon)     | 23231 SSH   |
| `postgres`   | Base de données primaire                  | interne     |
| `redis`      | Cache + pub/sub                           | interne     |
