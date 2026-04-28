# Choix technologiques — GYT

## Principe directeur

Chaque choix vise trois objectifs : **séparation claire des responsabilités**, **contrats inter-services explicites**, et **déploiement reproductible par un seul développeur** (`docker compose up`).

---

## Go — Backend, Gateway, Live

**Pourquoi :** Go est le langage le plus adapté à la construction de services réseau à haute concurrence avec une empreinte mémoire réduite. Ses goroutines permettent de gérer des milliers de connexions WebSocket simultanées dans le service `live` sans surcoût de threading OS. La bibliothèque standard couvre HTTP, TLS, et les primitives de synchronisation — zéro dépendances pour les briques essentielles.

**Pourquoi pas Rust :** La courbe d'apprentissage et la complexité du borrow checker auraient ralenti l'itération sur un projet de cette taille sans gain significatif (pas de hot-path critique en mémoire partagée).

**Pourquoi pas Node/Python :** Le modèle event-loop de Node contraint les CPU-bound tasks ; Python porte un overhead d'interprétation incompatible avec un serveur gRPC performant.

---

## gRPC + Protobuf — Communication inter-services

**Pourquoi :** gRPC impose un contrat binaire généré automatiquement depuis un fichier `.proto`. Toute modification d'interface est détectée à la compilation — pas de désalignement silencieux entre services. Le transport HTTP/2 multiplex permet des appels concurrents sur une seule connexion TCP, ce qui réduit la latence intra-réseau Docker.

**Alternative écartée — REST/JSON :** JSON est verbeux, non typé à la sérialisation, et les erreurs de contrat ne remontent qu'à l'exécution.

**Alternative écartée — NATS/RabbitMQ :** Les appels backend→soft-serve sont synchrones et requête-réponse par nature ; un bus de messages aurait ajouté une complexité opérationnelle sans valeur.

---

## GraphQL (gqlgen) — API Gateway

**Pourquoi :** Le frontend a besoin d'une interface flexible où chaque vue peut demander exactement les champs dont elle a besoin (over-fetching nul). GraphQL Subscriptions couvrent les cas d'usage temps réel (événements PR, repo) sans endpoint WebSocket ad hoc. `gqlgen` génère le resolver scaffolding depuis le schéma — le schéma est la source de vérité unique.

**Alternative écartée — REST :** Nécessiterait de multiples endpoints et versioning manuel ; sous-optimal pour un frontend riche.

**Alternative écartée — tRPC :** Couplage trop fort frontend/backend (TypeScript only) ; empêche d'exposer l'API à des clients tiers.

---

## Next.js 15 + Apollo Client — Frontend

**Pourquoi Next.js :** SSR natif pour les pages publiques (profils, repos publics) sans sacrifier l'interactivité côté client. Le routing basé sur le système de fichiers (`app/`) structure le code de façon prévisible. TypeScript intégré.

**Pourquoi Apollo Client :** Cache normalisé par identifiant — une mise à jour d'un repo dans le cache se propage à tous les composants qui le référencent. `useQuery`/`useMutation` intégrés dans React, gestion du loading/error déclarative.

---

## soft-serve — Serveur Git

**Pourquoi :** soft-serve (fork Charmbracelet adapté) expose nativement SSH, HTTP smart, et le protocole Git daemon sur le même binaire. Il supporte un management gRPC qui permet au `backend` de créer/supprimer/configurer des dépôts programmatiquement sans scripts shell. Il stocke les dépôts sous forme de bare repos sur le filesystem, compatible avec tout client git standard.

**Alternative écartée — Gitea/Forgejo :** Ce sont des plateformes complètes avec leur propre interface et base de données — redondant avec l'objectif du projet. Impossible à intégrer proprement via gRPC.

**Alternative écartée — libgit2 embarqué :** Gérer le service SSH et le protocole smart-HTTP en interne aurait représenté des mois de travail non différenciant.

---

## PostgreSQL — Base de données principale

**Pourquoi :** Schéma relationnel riche avec de nombreuses foreign keys (user→repo→PR→review→comment). ACID garantit la cohérence des opérations critiques (merge PR, transfer de repo). JSONB disponible pour les métadonnées flexibles (payload webhook). Support natif dans GORM.

**Alternative écartée — MySQL :** Gestion des transactions et des contraintes historiquement moins robuste ; JSON moins expressif.

**Alternative écartée — MongoDB :** Les données sont fortement relationnelles ; un document store aurait forcé à dénormaliser manuellement ce que le moteur SQL fait automatiquement.

---

## Redis — Cache + Pub/Sub

**Deux usages distincts sur la même instance :**

1. **Cache (backend)** : Les requêtes répétées (liste de commits, arbre de fichiers) sont servies depuis Redis avec un TTL. Réduit la charge sur PostgreSQL et sur soft-serve pour les lectures à haute fréquence.

2. **Pub/Sub (live)** : Les événements de review (curseur, commentaire, ligne sélectionnée) sont publiés dans des channels Redis. Toutes les instances du service `live` souscrivent et broadcastent aux WebSocket connectés. Cela rend le service `live` horizontalement scalable sans état partagé en mémoire.

**Alternative écartée pour le pub/sub — Kafka :** Kafka est conçu pour la persistance de logs à débit élevé. Les événements de review sont éphémères et à faible volume ; l'overhead opérationnel de Kafka n'est pas justifié.

---

## HAProxy — Reverse proxy

**Pourquoi :** HAProxy est le seul service qui parle au monde extérieur. Il termine TLS (SSL offloading), route le trafic HTTP par préfixe de chemin, et effectue un **TCP passthrough** pour le port SSH 23231 — les paquets SSH sont transmis tels quels à soft-serve sans interprétation HTTP. Cette séparation nette garantit que seul HAProxy gère la cryptographie TLS et l'exposition réseau.

**Alternative écartée — Nginx :** Nginx ne supporte pas le TCP passthrough sur le même port que l'HTTP avec la même ergonomie de configuration que HAProxy.

**Alternative écartée — Traefik :** Excellent pour le discovery dynamique (k8s), surdimensionné pour une stack Docker Compose statique.

---

## Docker Compose — Déploiement

**Pourquoi :** Un fichier `docker-compose.yml` de base + un `docker-compose.override.yml` de développement couvre les deux modes (prod avec TLS, dev HTTP local) sans duplication. Les health checks Docker Compose garantissent l'ordre de démarrage des services sans scripts d'attente artisanaux.

**Ce que ce choix implique :** Pas de Kubernetes. L'objectif était la reproductibilité sur une machine unique (serveur VPS ou poste développeur), pas l'orchestration multi-nœuds. La conception des services (stateless gateway, pub/sub live) rend une migration vers k8s possible sans refonte.
