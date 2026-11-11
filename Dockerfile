# Image du service : le serveur HTTP, le worker et les jobs en partagent le
# contenu et ne diffèrent que par leur commande.
#
# L'étiquette de l'image de base sert à la lecture, l'empreinte fait foi. Debian
# 13 est retenue parce que ses dépôts officiels fournissent le client
# PostgreSQL 17. L'image est écrite en clair dans une instruction FROM, la seule
# forme que Dependabot sait suivre. NODE_IMAGE permet de tirer la même image
# depuis un miroir ; par défaut, il désigne l'étape qui porte l'image officielle.
ARG NODE_IMAGE=node-officielle
FROM node:24.22.2-trixie-slim@sha256:0820eaa85e07d0490446dd01d14707e17e6108a36988cf374899cd057eb3812d AS node-officielle

FROM ${NODE_IMAGE} AS base
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/core/package.json packages/core/
COPY apps/jobs/package.json apps/jobs/
COPY apps/server/package.json apps/server/
COPY apps/worker/package.json apps/worker/
# corepack installe la version de pnpm que fixe package.json, et vérifie son
# empreinte.
RUN corepack enable && corepack install

FROM base AS build
RUN pnpm install --frozen-lockfile
COPY tsconfig.base.json ./
COPY packages packages
COPY apps apps
RUN pnpm run build

# Dépendances d'exécution seules, sans les outils de développement.
FROM base AS runtime-dependencies
RUN pnpm install --frozen-lockfile --prod

FROM ${NODE_IMAGE}
# pg_dump sert au job verify, qui contrôle la sauvegarde de la table témoin.
RUN apt-get update \
  && apt-get install --yes --no-install-recommends postgresql-client-17 \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=runtime-dependencies /app ./
COPY --from=build /app/packages/core/dist packages/core/dist
COPY --from=build /app/apps/jobs/dist apps/jobs/dist
COPY --from=build /app/apps/server/dist apps/server/dist
COPY --from=build /app/apps/worker/dist apps/worker/dist
COPY db db
# Fichiers de déploiement : l'instance les extrait de l'image qu'elle s'apprête
# à lancer, pour que le code et sa mise en service aient toujours la même version.
COPY deploy/release /opt/deploy

# Identifiant du commit. /health l'annonce et le déploiement s'en sert pour
# vérifier que la version attendue est bien celle qui répond.
ARG APP_VERSION
ENV NODE_ENV=production \
    APP_VERSION="${APP_VERSION:?argument de construction obligatoire}"
LABEL org.opencontainers.image.title="memoire" \
      org.opencontainers.image.description="Mémoire long terme : serveur HTTP, worker et jobs" \
      org.opencontainers.image.source="https://github.com/ArnaudLut/Memories" \
      org.opencontainers.image.revision="${APP_VERSION}"

USER node
EXPOSE 8080
CMD ["node", "apps/server/dist/main.js"]
