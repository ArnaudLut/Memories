# Mémoire long terme

Ce dépôt contient le service « Mémoire long terme » et tout ce qui sert à
l'exploiter : son code, le schéma de sa base, la description de son
infrastructure chez OVHcloud et les workflows qui le construisent et le
déploient. Le service est destiné à garder un profil, la mémoire d'un contexte
de travail, un backlog par projet et des relations, qu'un assistant consultera
par un connecteur.

L'étape 1 en livre le squelette, sans aucune de ces fonctions :

- un service HTTP dont la seule route, `/health`, annonce la version en ligne
  et l'état de la base ;
- un worker relié à la file de tâches, qui n'y traite encore qu'un battement
  périodique ;
- une base PostgreSQL 17 avec pgvector, cinq rôles SQL aux droits séparés et
  une table témoin cloisonnée par tenant ;
- l'environnement `preview` chez OVHcloud, à Gravelines, décrit avec OpenTofu
  et déployé par GitHub Actions à chaque commit de `main`.

[`BOOTSTRAP.md`](BOOTSTRAP.md) décrit la mise en route sur un compte OVHcloud :
les gestes qui restent manuels, leur coût, et ce que seuls les services réels
peuvent encore confirmer.

## Arborescence

```text
apps/server/     service HTTP
apps/worker/     worker de la file de tâches
apps/jobs/       jobs ponctuels : db-bootstrap, migrate et verify
packages/core/   code commun : configuration, journal, accès à la base,
                 amorçage et migrations
db/bootstrap/    SQL joué avec le compte d'administration de la base : rôles,
                 schémas, extensions
db/migrations/   migrations, jouées par le rôle migrator à chaque déploiement
dev/             base PostgreSQL locale, pour le développement et les tests
deploy/          ce qui s'exécute sur l'instance : premier démarrage, canal de
                 déploiement, pile Docker Compose
infra/           OpenTofu : amorçage, environnements, modules et garde-fou des
                 plans
scripts/         bootstrap.sh, lancé depuis le poste du fondateur, et ci/, les
                 scripts des workflows
.github/         workflows GitHub Actions et réglage de Dependabot
Dockerfile       image commune au serveur, au worker et aux jobs
```

## Développement local

Il faut Node.js 24, à la version que donne `.node-version`, et Docker avec
Compose. `corepack`, livré avec Node.js, fournit la version de pnpm que fixe
`package.json`. `dev/compose.yaml` lance PostgreSQL 17 avec pgvector, et
`.env.example` porte les valeurs de la base locale.

```sh
corepack enable
pnpm install
docker compose -f dev/compose.yaml up -d --wait
cp .env.example .env
pnpm build
node --env-file=.env apps/jobs/dist/cli.js db-bootstrap
node --env-file=.env apps/jobs/dist/cli.js migrate
node --env-file=.env apps/server/dist/main.js
```

Le job `db-bootstrap` crée les rôles SQL, les schémas et les extensions, et
`migrate` joue les migrations. Le service répond ensuite sur
`http://127.0.0.1:8080/health` :

```json
{"status":"ok","version":"dev","env":"development","checks":{"database":"ok","migrations":"0001"}}
```

Le worker se lance de la même façon, avec `apps/worker/dist/main.js`. Pour
repartir de zéro, `docker compose -f dev/compose.yaml down --volumes` supprime
la base locale.

Les contrôles sont ceux de l'intégration continue. `pnpm lint` passe Biome,
dont `pnpm format` applique les corrections ; `pnpm test` lance les tests
unitaires, sans base, et `pnpm test:integration` les tests sur la base locale.

```sh
pnpm lint
pnpm typecheck
pnpm test
pnpm test:integration
```

Les tests d'intégration créent leurs propres bases, nommées `memoire_test_*` :
il leur suffit du conteneur de `dev/compose.yaml`. Comme le job `verify`, ils
appellent `pg_dump`, qui doit être en version 17 : une version plus ancienne
refuse de sauvegarder ce serveur. Sous Linux, `scripts/ci/pg17` fournit celui
du conteneur de la base, sans rien installer :

```sh
PATH="$PWD/scripts/ci/pg17:$PATH" pnpm test:integration
```

Si le port 5432 est déjà pris, la variable `MEMOIRE_PG_PORT` en donne un autre
au conteneur. `PGPORT` doit alors recevoir la même valeur, dans `.env` et dans
l'environnement des tests.

[`infra/README.md`](infra/README.md) décrit les contrôles de l'infrastructure,
qui ne demandent aucun compte, l'articulation des piles OpenTofu et le
garde-fou des plans.

## Déploiement

Une fois le dépôt amorcé, le workflow « Déployer » met en ligne chaque commit
de `main` :

1. Il construit l'image, y inscrit l'identifiant du commit et la publie sur
   `ghcr.io/arnaudlut/memories`. La suite ne la désigne que par son empreinte.
2. Il planifie `infra/envs/preview`. Le garde-fou `infra/policy/check_plan.py`
   refuse un plan qui supprime ou remplace le projet, la base ou un bucket ;
   un plan accepté est appliqué tel qu'il a été enregistré.
3. Il tire la configuration de l'application des sorties d'OpenTofu et
   l'envoie à l'instance par SSH, où la clé de la CI ne permet qu'une commande.
4. Sur l'instance, `deploy.sh`, livré dans l'image, joue les migrations,
   démarre la nouvelle version et contrôle qu'elle annonce le bon commit.
   Sinon, il remet en service la version précédente, s'il y en a une.
5. Il attend enfin que `/health` annonce ce commit sur le nom public.

Aucun déploiement ne se sert du compte d'administration de la base : le
workflow « Amorcer la base » le fait, à la demande. Le tableau qui ouvre
[`BOOTSTRAP.md`](BOOTSTRAP.md) présente les autres workflows.
