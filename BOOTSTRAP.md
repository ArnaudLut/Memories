# Amorçage de l'étape 1

Ce document décrit les gestes qui restent à faire à la main pour mettre la
préversion en ligne. Il y en a cinq, à faire dans l'ordre, et presque tous ne se
font qu'une fois. Tout le reste est automatisé : la première partie dit
précisément par quoi.

Chaque geste indique pourquoi il reste manuel, ce qu'il faut faire, ce qu'il
crée et ce qu'il coûte, puis comment vérifier qu'il a réussi. Les exemples
utilisent la zone `memoire.example.com` et le nom
`preview.memoire.example.com` : remplacez-les par les vôtres.

Aucune de ces opérations n'a pu être essayée sur un vrai compte OVHcloud ni sur
GitHub avant votre première exécution. La partie « Ce qui reste à vérifier sur
les services réels » dit ce que cette exécution doit confirmer, et quoi faire
dans les cas prévus.

## Ce qui est automatisé, et ce qui ne l'est pas

| Automatisme | Déclenchement | Ce qu'il fait |
| --- | --- | --- |
| `scripts/bootstrap.sh` | Vous, sur votre poste, au geste 3 | Crée chez OVHcloud le compte de service de la CI, sa politique IAM, le bucket des états et sa clé S3. Génère la phrase de passe des états. Inscrit 5 secrets et 10 variables dans le dépôt GitHub. |
| Workflow « Intégration continue » | Chaque pull request, chaque commit de `main` | Contrôle le code, les tests, l'image, les fichiers OpenTofu, les scripts et les workflows. Une fois le dépôt amorcé, ajoute le plan de la préversion au résumé des pull requests. |
| Workflow « Déployer » | Chaque commit de `main`, ou à la demande | Construit l'image et la publie sur `ghcr.io/arnaudlut/memories`. Planifie l'infrastructure de la préversion, soumet le plan au garde-fou et l'applique. Met la version en service sur l'instance, puis attend que `/health` annonce le commit. |
| Workflow « Amorcer la base » | À la demande, au geste 4 | Fait générer par OVHcloud un nouveau mot de passe pour le compte d'administration de la base, puis crée les rôles SQL, les schémas et les extensions. |
| Workflow « Vérifier l'étape 1 » | À la demande, au geste 5 | Contrôle sur les services réels les rôles SQL, pgvector, le cloisonnement et la sauvegarde de la table témoin, le verrou de l'état, et l'absence de changement en attente. |
| Workflow « Détecter une dérive » | Chaque lundi, ou à la demande | Planifie la préversion et échoue si le plan propose un changement. |
| Workflow « Lever le verrou de l'état » | À la demande, après une exécution annulée ou interrompue | Lève le verrou qu'OpenTofu a pu laisser sur l'état de la préversion. |
| Dependabot | Chaque semaine | Ouvre les pull requests qui font avancer les versions épinglées. |

Restent manuels, dans cet ordre :

1. créer le projet Public Cloud et y saisir le bon d'achat ;
2. héberger la zone DNS chez OVHcloud ;
3. créer des identifiants personnels temporaires et lancer
   `scripts/bootstrap.sh` ;
4. fusionner la pull request, lancer une fois le workflow « Amorcer la base »,
   puis relancer le déploiement ;
5. lancer le workflow « Vérifier l'étape 1 » et lire son tableau.

En dehors du projet et de la zone DNS, aucune ressource OVHcloud n'est créée à
la main.

Tant que la variable `OVH_BOOTSTRAPPED` du dépôt ne vaut pas `true`, aucun
workflow ne touche à OVHcloud : seule l'intégration continue tourne, sans aucun
secret. C'est `scripts/bootstrap.sh` qui pose cette variable, en dernier.

## Ce que cela coûte

Les prix sont hors taxes, lus le 10 novembre 2026 sur la grille Public Cloud
d'OVHcloud.

| Poste | Créé par | Coût mensuel |
| --- | --- | --- |
| Base PostgreSQL managée, offre Essential, gabarit DB1-4 | Le workflow « Déployer » | 54,46 € |
| Instance `d2-2` | Le workflow « Déployer » | 5,71 € au tarif mensuel, environ 7,59 € au tarif horaire |
| Bucket des états, zone DNS, réseau privé, images sur GitHub | Les gestes 2 et 3, le workflow « Déployer » | Moins de 1 € au total (estimation) |
| **Total tant que seule la préversion existe** | | **Environ 60 €** |

La dépense commence au geste 4, quand le premier déploiement crée l'instance et
la base. Elle est imputée d'abord au bon d'achat, puis au moyen de paiement du
compte.

Un bon d'achat a une date de fin de validité. D'après le guide d'OVHcloud, un
bon n'est en général valable qu'un mois, et les crédits du Startup Program
douze mois après la signature du contrat. Passé cette date, le solde restant
n'est plus utilisable et toute la dépense passe au moyen de paiement. Relevez
cette date au geste 1, puis enchaînez les gestes sans attendre.

Trois points sont à constater sur la première facture. Le code ne demande pas
d'engagement mensuel pour l'instance : attendez-vous au tarif horaire, soit un
total de 62,05 € au lieu de 60,17 €. L'adresse IPv4 publique pourrait être
facturée à part, 1,97 € par mois : la grille ne le dit pas clairement pour cette
gamme. OVHcloud annonce enfin qu'après décembre 2026 une base sera facturée sur
trois lignes, calcul, stockage et sauvegardes, au lieu d'une seule : comparez
leur somme aux 54,46 € du tableau.

Le nom de domaine et une éventuelle offre GitHub payante ne sont pas comptés.

Aucune commande du dépôt ne supprime la base : la CI n'en a pas le droit, et le
code le refuse. Pour arrêter la dépense de la préversion :

1. Désarmez d'abord les workflows, sans quoi le prochain commit de `main`
   recréerait l'instance et la base :
   `gh variable set OVH_BOOTSTRAPPED --body false`.
2. Dans l'espace client, ouvrez le service PostgreSQL `memoire-preview` et
   désactivez sa protection contre la suppression, puis supprimez ce service
   et l'instance `memoire-preview`. Les données de la base sont perdues.

Le bucket des états, la zone DNS, le réseau privé et les images peuvent
rester : ils coûtent moins de 1 € par mois. Pour reprendre, remettez la
variable à `true`, puis relancez le déploiement comme à l'étape 4.3 : il recrée
l'instance et une base vide, et s'arrête avec le code 12 tant que la base n'est
pas de nouveau amorcée, comme à l'étape 4.2.

## Avant de commencer

Il vous faut :

- le compte OVHcloud de la société, protégé par une double authentification,
  avec un moyen de paiement valide, et le code du bon d'achat si vous en avez
  un ;
- un nom de domaine dont la société maîtrise le DNS ;
- les droits d'administration sur le dépôt GitHub, pour y écrire des secrets et
  fusionner ;
- un gestionnaire de mots de passe ;
- un poste sous Linux ou macOS avec `git`, OpenTofu 1.13, `gh` 2.43 ou plus
  récent, `jq`, `openssl`, `curl` et `dig` ;
- une copie du dépôt sur ce poste, placée sur la branche de la pull request de
  l'étape 1 (`gh pr checkout <numéro>`) tant qu'elle n'est pas fusionnée.

Vérifiez le poste depuis la racine du dépôt :

```sh
tofu version       # OpenTofu v1.13.x
gh --version       # 2.43 ou plus récent
gh auth status     # connecté à github.com ; sinon « gh auth login »
jq --version && openssl version && curl --version && dig -v
gh repo view --json nameWithOwner --jq .nameWithOwner
```

La dernière commande doit afficher le dépôt de la société : c'est dans ce
dépôt, et dans aucun autre, que le geste 3 écrira les secrets.

## Geste 1 : créer le projet Public Cloud et saisir le bon d'achat

**Pourquoi à la main.** Créer un projet revient à passer une commande sur le
compte : il faut accepter des contrats, valider un moyen de paiement et saisir
le code du bon d'achat, ce que le formulaire de l'espace client fait en une
fois. Le code du dépôt, lui, ne fait que lire le projet : aucun automatisme ne
peut ainsi le résilier.

**Ce qu'il faut faire.** Connectez-vous à l'espace client
(`https://manager.eu.ovhcloud.com`) avec le compte de la société, puis ouvrez
« Public Cloud ». La suite dépend du compte.

Si le compte a déjà un projet Public Cloud :

1. Sur la page « Projets », cliquez sur « Créer un nouveau projet ».
2. Sur la page « Créer un projet Public Cloud », renseignez « Nom du projet »,
   par exemple `memoire`.
3. Dans la section « Contrats », cochez la case après lecture.
4. Dans la section « Vérifiez votre identité avec un moyen de paiement »,
   sélectionnez le moyen de paiement.
5. Dans la section « Vous avez un code promo ? », saisissez le code du bon
   d'achat et cliquez sur « Ajouter ».
6. Cliquez sur « Créer mon projet ».

Si c'est le premier projet Public Cloud du compte, l'espace client ouvre la page
« Bienvenue dans l'écosystème Public Cloud » :

1. Cochez la case de la section « Contrats », puis cliquez sur « Découvrir
   l'univers Public Cloud ». Le projet est créé en « mode découverte », qui ne
   permet de créer aucune ressource.
2. Sur la page d'accueil du projet, dans le bandeau « Démarrez le déploiement
   de vos ressources Cloud. », cliquez sur « Activer », puis sur « Activer
   votre projet ».
3. Sur la page « Activer votre projet », validez un moyen de paiement, puis
   cliquez sur « Activer votre projet ».
4. Dans le menu de gauche du projet, ouvrez « Centre de coûts », puis l'onglet
   « Crédits et bons d'achat ». Cliquez sur « Activer un voucher », saisissez
   le code dans « Votre voucher », puis cliquez sur « Activer ».

Certains comptes ne se voient pas proposer le mode découverte : leur premier
projet se crée alors par le formulaire du premier cas.

Les crédits du Startup Program s'appliquent sans code. OVHcloud les active dans
les 48 heures ouvrées qui suivent la signature du contrat, puis les impute de
lui-même aux factures Public Cloud.

Relevez enfin l'identifiant du projet : 32 caractères, des chiffres et des
lettres de `a` à `f`. En haut du menu de gauche, cliquez sur le sélecteur
« Projet » : la liste affiche l'identifiant de chaque projet sous son nom, avec
une icône pour le copier.

**Ce que le geste crée et coûte.** Un projet vide, qui ne coûte rien tant
qu'aucune ressource n'y est créée.

**Comment vérifier.**

- Le projet apparaît dans le sélecteur « Projet », en haut du menu de gauche,
  sans bandeau de mode découverte.
- L'onglet « Crédits et bons d'achat » du « Centre de coûts » affiche le solde
  du bon. Relevez sa date de fin de validité. Si l'onglet ne la montre pas, la
  console de l'API (`https://api.eu.ovhcloud.com/console/`) la donne :
  `GET /cloud/project/{serviceName}/credit` liste les crédits du projet, et
  `GET /cloud/project/{serviceName}/credit/{id}` renvoie la date dans le champ
  `validity`. Les crédits du Startup Program se lisent ailleurs : cliquez sur
  votre nom en haut à droite, puis sur « Mes moyens de paiement », onglet « Mes
  bons d'achat ».

## Geste 2 : héberger la zone DNS chez OVHcloud

**Pourquoi à la main.** Créer une zone est une commande passée sur le compte,
et la rendre active demande une modification chez le gestionnaire actuel du
domaine. Le déploiement ne gère ensuite qu'un enregistrement dans cette zone.
La CI reçoit pourtant le droit de créer, de modifier et de supprimer tous les
enregistrements de la zone, et aucun autre droit sur le domaine : mieux vaut
lui confier une zone qui ne porte rien d'autre.

**Ce qu'il faut faire.** La zone doit se trouver sur le même compte OVHcloud
que le projet. Trois cas se présentent.

Le domaine est enregistré chez OVHcloud, sur ce compte, avec les serveurs DNS
d'OVHcloud : la zone existe déjà. Si le domaine ne sert à rien d'autre, il n'y
a rien à faire. S'il porte déjà un site ou des courriels, créez plutôt une zone
pour un sous-domaine en suivant les étapes du cas suivant : à l'étape 5, les
deux enregistrements NS s'ajoutent dans la zone du domaine, par le bouton
« Ajouter une entrée ».

Le domaine est géré ailleurs et sert déjà à autre chose, un site ou des
courriels : déléguez seulement un sous-domaine, par exemple
`memoire.example.com`.

1. Dans l'espace client, ouvrez « Web Cloud », puis « Zones DNS », et cliquez
   sur « Commander ».
2. Saisissez le sous-domaine et attendez la fin des vérifications.
3. À la question « Activer les entrées minimales ? », répondez « Oui », puis
   suivez les étapes jusqu'à la création de la zone. Si elle n'apparaît pas
   dans la liste, patientez une vingtaine de minutes et rechargez la page.
4. Ouvrez la zone et relevez, dans la colonne « Cible », les deux lignes de
   type « NS ». Elles ont la forme `nsXX.ovh.net` et `dnsXX.ovh.net`.
5. Chez le gestionnaire actuel du domaine, ajoutez pour le sous-domaine deux
   enregistrements de type NS qui désignent ces deux serveurs.

Le domaine est géré ailleurs et ne sert à rien d'autre : suivez les mêmes
étapes en saisissant le domaine lui-même, puis remplacez chez son bureau
d'enregistrement les serveurs DNS du domaine par les deux serveurs relevés.
Toute la résolution du domaine passe alors par OVHcloud.

La propagation peut prendre jusqu'à 48 heures.

Le nom saisi à la commande, ou le domaine lui-même dans le premier cas, est la
zone que le geste 3 attend dans `--dns-zone`. Choisissez enfin le nom de la
préversion. Il doit appartenir à la zone, par exemple
`preview.memoire.example.com`, et ne porter encore aucun enregistrement.

**Ce que le geste crée et coûte.** Une zone DNS chez OVHcloud, à 0 € d'après le
catalogue lu le 10 novembre 2026. Le nom de domaine reste facturé par son
bureau d'enregistrement.

**Comment vérifier.**

```sh
dig +short NS memoire.example.com            # les deux serveurs d'OVHcloud
dig +short preview.memoire.example.com       # rien pour l'instant
```

## Geste 3 : créer des identifiants temporaires et lancer `scripts/bootstrap.sh`

**Pourquoi à la main.** Le compte de service de la CI n'existe pas encore, et
il ne peut pas se créer lui-même : il faut une identité qui a déjà le droit de
créer des comptes de service et des politiques IAM, la vôtre. Ces droits sont
trop larges pour être confiés à GitHub. Ils servent donc une fois, depuis votre
poste, avec des identifiants que vous révoquez aussitôt.

### 3.1 Décider des accès d'administration

Cette décision se prend avant le premier déploiement : changer la liste des
clés plus tard réinstalle l'instance, efface son disque et fait redemander un
certificat.

Sans clé, l'instance n'accepte que le canal de déploiement. Personne ne peut y
ouvrir de session, et un dépannage passe par le mode rescue d'OVHcloud. C'est
le réglage par défaut. Dans ce cas, personne ne peut non plus lire les journaux
du service : seules les 40 dernières lignes de chaque conteneur d'une version
refusée paraissent dans le journal de l'étape « Mettre la version en service ».

Avec une ou plusieurs clés publiques, l'instance reçoit un compte `ops` qui a
tous les droits par `sudo`. La valeur est une liste JSON :

```sh
gh variable set ADMIN_SSH_PUBLIC_KEYS --body '["ssh-ed25519 AAAA... prenom@poste"]'
```

`scripts/bootstrap.sh` n'écrase jamais une valeur déjà inscrite. Après le
premier déploiement, vérifiez le compte :
`ssh ops@preview.memoire.example.com sudo cloud-init status --long` doit
annoncer `status: done`.

### 3.2 Créer les identifiants personnels

1. Ouvrez
   `https://api.eu.ovhcloud.com/createToken/?GET=/*&POST=/*&PUT=/*&DELETE=/*`
   et connectez-vous avec le compte de la société.
2. Donnez un nom à l'application, par exemple `memoire-bootstrap`, et une
   description.
3. Choisissez la durée de validité la plus courte qui couvre l'opération : une
   journée suffit.
4. Vérifiez que les quatre droits `GET`, `POST`, `PUT` et `DELETE` portent sur
   `/*`, puis cliquez sur « Create keys ».
5. La page affiche trois valeurs : la clé d'application, le secret
   d'application et la clé de consommateur. Gardez-la ouverte jusqu'à l'étape
   suivante, sans rien en copier ailleurs.

Ces droits couvrent tout le compte. Ce sont ceux que demande la documentation
du fournisseur OpenTofu d'OVHcloud ; la protection tient à leur courte durée de
vie et à leur révocation, à l'étape 3.5.

### 3.3 Lancer la commande

Ne partagez pas votre écran pendant cette étape : la page des identifiants et
la phrase de passe s'affichent en clair.

Dans un terminal placé à la racine du dépôt, saisissez les trois valeurs sans
les écrire dans un fichier ni dans l'historique du terminal. Chaque commande
attend que vous colliez la valeur puis que vous appuyiez sur Entrée, et
n'affiche rien :

```sh
read -rs OVH_APPLICATION_KEY && export OVH_APPLICATION_KEY
read -rs OVH_APPLICATION_SECRET && export OVH_APPLICATION_SECRET
read -rs OVH_CONSUMER_KEY && export OVH_CONSUMER_KEY
```

Puis :

```sh
scripts/bootstrap.sh \
  --project-id <identifiant du projet> \
  --dns-zone memoire.example.com \
  --preview-hostname preview.memoire.example.com \
  --acme-email contact@example.com
```

L'adresse de contact est transmise à l'autorité qui délivre les certificats,
Let's Encrypt et elle seule, et inscrite dans une variable du dépôt : une
adresse de fonction convient mieux qu'une adresse personnelle. Une valeur omise
est reprise du dépôt s'il la connaît déjà, et demandée au clavier sinon.

La commande déroule alors ces étapes :

1. Elle affiche « Dépôt GitHub : », suivi du dépôt où elle écrira, puis
   « Projet Public Cloud : », suivi du nom du projet. Si l'un des deux n'est
   pas le bon, interrompez-la : rien n'a encore été créé.
2. Elle génère la phrase de passe qui chiffre les états OpenTofu et l'affiche
   une seule fois. Enregistrez-la aussitôt dans votre gestionnaire de mots de
   passe, puis appuyez sur Entrée. Sans elle, les états sont illisibles et
   OpenTofu ne peut plus rien modifier ; GitHub en reçoit une copie, qu'il ne
   permet pas de relire.
3. OpenTofu présente son plan, qui doit annoncer
   `Plan: 6 to add, 0 to change, 0 to destroy.`, suivi de la liste des sorties,
   puis attend à l'invite `Enter a value:`. Répondez `yes`.
4. Après `Apply complete! Resources: 6 added, 0 changed, 0 destroyed.`, elle
   inscrit les variables puis les secrets dans le dépôt, une ligne par valeur.
5. Elle range son état, chiffré, dans le bucket, et supprime la copie locale.
6. Elle pose `OVH_BOOTSTRAPPED`, puis affiche « Amorçage terminé. » et la suite
   des opérations.

Si OpenTofu affiche l'avertissement « Le projet ne semble rattaché à aucun
vRack », la commande va quand même à son terme, mais le premier déploiement ne
pourra pas créer le réseau privé. Commandez alors un vRack, gratuit, dans la
rubrique vRack de l'espace client, puis rattachez-lui le projet depuis l'onglet
des services attachés, avant le geste 4. Les projets récents en reçoivent un à
leur création.

### 3.4 En cas d'arrêt avant la fin

La commande se relance sans risque : elle reprend où elle s'était arrêtée. Trois
règles suffisent.

- Ne supprimez pas `infra/bootstrap/terraform.tfstate` : ce fichier, chiffré et
  ignoré par git, est l'état en cours.
- Exportez la phrase de passe avant de relancer :
  `read -rs STATE_PASSPHRASE && export STATE_PASSPHRASE`.
- Ne révoquez les identifiants personnels qu'après le message « Amorçage
  terminé. ».

Si l'arrêt survient juste après la création de la clé S3, sur une erreur 403 ou
`InvalidAccessKeyId` pendant l'envoi de l'état vers le bucket, attendez une
minute et relancez la même commande.

### 3.5 Révoquer les identifiants personnels

Révoquez l'application `memoire-bootstrap` sur la page « Clés API » de l'espace
client. À défaut, la console de l'API (`https://api.eu.ovhcloud.com/console/`)
le fait en trois appels : `GET /me/api/application` donne les identifiants des
applications, `GET /me/api/application/{applicationId}` donne le nom de
chacune, et `DELETE /me/api/application/{applicationId}` révoque celle qui
s'appelle `memoire-bootstrap`.

Fermez ensuite le terminal : la phrase de passe y reste affichée. Si vous devez
le garder ouvert, retirez au moins les valeurs de son environnement :

```sh
unset OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY STATE_PASSPHRASE
```

**Ce que le geste crée et coûte.** Chez OVHcloud, six objets :

- le compte de service `memoire-ci`, et la politique IAM du même nom, qui
  limite ses droits à 35 actions sur le projet et sur la zone DNS, sans pouvoir
  commander ni résilier un service, ni supprimer la base ;
- le bucket `memoire-state-<identifiant du projet>`, à Gravelines, versionné ;
- un utilisateur du projet, décrit comme `memoire-state`, sa clé S3 et la
  politique qui la limite à ce bucket.

Dans le dépôt GitHub :

- les secrets `OVH_CLIENT_ID`, `OVH_CLIENT_SECRET`, `STATE_S3_ACCESS_KEY`,
  `STATE_S3_SECRET_KEY` et `STATE_PASSPHRASE` ;
- les variables `OVH_ENDPOINT`, `OVH_PROJECT_ID`, `STATE_BUCKET`,
  `STATE_REGION`, `STATE_ENDPOINT`, `DNS_ZONE`, `PREVIEW_HOSTNAME`,
  `ACME_EMAIL`, `ADMIN_SSH_PUBLIC_KEYS` et `OVH_BOOTSTRAPPED`.

Le bucket ne contient que quelques fichiers d'état : son coût se compte en
centimes. Le reste est gratuit.

**Comment vérifier.**

```sh
gh secret list      # les cinq secrets
gh variable list    # les dix variables, dont OVH_BOOTSTRAPPED à true
git status --short --ignored infra/bootstrap
```

La dernière commande ne doit afficher que `!! infra/bootstrap/.terraform/` :
aucun état ne reste alors sur le poste. Une ligne qui nomme
`terraform.tfstate` signale une exécution interrompue, à reprendre comme à
l'étape 3.4.

Dans l'espace client, le menu de gauche du projet montre le bucket dans la
section « Stockage », et l'utilisateur dans « Gestion du projet », onglet
« Utilisateurs ». Le répertoire `infra/bootstrap/.terraform`, ignoré par git,
peut être supprimé : il ne contient aucun secret.

Vous pouvez aussi lire, avant de fusionner, ce que le premier déploiement
créera. Fermez puis rouvrez la pull request :

```sh
gh pr close <numéro>
gh pr reopen <numéro>
```

GitHub lance alors une nouvelle exécution du workflow « Intégration
continue », qui lit les variables que `scripts/bootstrap.sh` vient d'inscrire.
Sa documentation ne promet pas qu'une simple relance des jobs les relise. Le
job « Plan de la préversion », ignoré jusque-là, s'exécute. Son résumé doit
annoncer « Plan accepté : aucune ressource protégée n'est supprimée ni
remplacée. » et, dans le plan complet,
`Plan: 14 to add, 0 to change, 0 to destroy.`

## Geste 4 : fusionner, amorcer la base, relancer le déploiement

**Pourquoi à la main.** La fusion est votre décision : c'est elle qui engage la
dépense. L'amorçage de la base se sert de son compte d'administration, dont
OVHcloud ne montre le mot de passe qu'au moment où il est défini. Le workflow
le fait régénérer, s'en sert une fois et ne le conserve nulle part : un
déploiement ne détient ainsi jamais ce compte, et s'en servir reste un acte
volontaire.

### 4.1 Fusionner

Fusionnez la pull request dans `main`. Le workflow « Déployer » démarre ;
suivez-le dans l'onglet « Actions » du dépôt, ou avec `gh run watch`.

- Le job « Image » construit l'image et la publie.
- Le job « Préversion » crée l'infrastructure. L'étape « Appliquer le plan
  enregistré » est longue la première fois : elle attend la création de la
  base, pendant 40 minutes au plus. Ne l'annulez pas : une création interrompue
  laisse la base à remplacer, ce que décrit la fin de `infra/README.md`.
- L'étape « Mettre la version en service » échoue ensuite avec le code 12, et
  le résumé du job indique : « La base n'est pas encore amorcée : lancez le
  workflow « Amorcer la base », puis relancez ce déploiement. »

Cet échec est attendu la première fois : la base existe, mais ses rôles SQL
pas encore.

Si la pull request a été fusionnée avant le geste 3, le workflow n'a rien
fait : lancez-le à la main, comme à l'étape 4.3.

Tant que le premier déploiement n'a pas abouti, le workflow « Détecter une
dérive » du lundi échoue : son plan annonce les ressources qui restent à créer.

### 4.2 Amorcer la base

```sh
gh workflow run db-bootstrap.yml --ref main
gh run watch
```

`gh run watch` propose de choisir l'exécution à suivre. S'il n'en trouve
aucune, attendez quelques secondes et relancez-le.

Dans l'interface, la même action se trouve dans l'onglet « Actions » : workflow
« Amorcer la base », bouton « Run workflow », branche `main`.

Le workflow doit se terminer en succès. Par la suite, relancez-le après le
déploiement de tout commit qui modifie `db/bootstrap` : un déploiement ne
rejoue pas ces fichiers.

### 4.3 Relancer le déploiement

```sh
gh workflow run deploy.yml --ref main
gh run watch
```

Cette fois, le résumé du job « Préversion » doit annoncer « Aucun changement :
l'infrastructure correspond à sa description. », puis « La version <commit>
répond sur https://preview.memoire.example.com/health. » Cette dernière étape
attend jusqu'à dix minutes, le temps que le premier certificat soit délivré.

**Ce que le geste crée et coûte.** Dans le projet OVHcloud : un réseau privé et
son sous-réseau, un groupe de sécurité, l'instance `memoire-preview`, le
service PostgreSQL `memoire-preview` et sa base `memoire`, et l'enregistrement
DNS de la préversion. Sur GitHub : l'image du service. C'est ici que commence
la dépense d'environ 60 € HT par mois.

**Comment vérifier.**

```sh
curl --silent https://preview.memoire.example.com/health
```

La réponse doit avoir cette forme, avec l'identifiant du dernier commit de
`main` :

```json
{"status":"ok","version":"<commit>","env":"preview","checks":{"database":"ok","migrations":"0001"}}
```

À partir de là, chaque fusion dans `main` déploie la préversion sans autre
geste.

**Si une étape échoue autrement.** Le journal de l'étape donne la cause, et le
workflow se relance sans risque : OpenTofu reprend là où il s'est arrêté, et
remettre en service la même version ne change rien.

**N'annulez pas une exécution pendant qu'OpenTofu planifie ou applique.** Il
tient alors le verrou de l'état. Une exécution annulée, arrêtée au bout des
deux heures du job ou privée de son runner peut le laisser en place : les
exécutions suivantes attendent dix minutes, puis échouent avec
`Error acquiring the state lock`. Vérifiez qu'aucun workflow ne tourne, relevez
l'identifiant `ID` que donne ce message, puis lancez :

```sh
gh workflow run state-unlock.yml --ref main -f lock_id=<ID>
```

Lancez ensuite « Détecter une dérive », qui planifie sans appliquer, et lisez
son plan avant de relancer le déploiement. Une base que le plan veut remplacer
se traite comme l'indique la fin de `infra/README.md`. Une ressource que le
plan veut créer alors que l'espace client la montre déjà, la base ou
l'enregistrement DNS en particulier, a été créée sans être inscrite dans
l'état : supprimez-la d'abord dans l'espace client, sans quoi elle serait créée
une seconde fois, et la base facturée deux fois.

| Étape en échec | Cause probable | Que faire |
| --- | --- | --- |
| Une étape d'OpenTofu, message « Error acquiring the state lock » | Une exécution annulée ou interrompue a laissé le verrou de l'état | Voir le paragraphe ci-dessus |
| « Planifier et passer le garde-fou », message « Resource instance cannot be destroyed » | Une création de la base a échoué en cours de route, et OpenTofu veut la remplacer | Voir la fin de `infra/README.md` |
| « Appliquer le plan enregistré » | Erreur 403, région ou offre indisponible, délai dépassé | Voir « À vérifier à la première application réelle » dans `infra/README.md` |
| « Mettre la version en service », code 1 ou 255 | L'instance n'a pas fini son premier démarrage | Relancer le déploiement |
| « Mettre la version en service », code 11 | L'instance n'a pas pu télécharger l'image | Lire le journal, puis relancer |
| « Mettre la version en service », code 13 | La nouvelle version n'est pas saine ; la précédente, s'il y en a une, est remise en service | Lire le journal de l'étape |
| « Mettre la version en service », code 14 | La migration de la base a échoué | Lire le journal de l'étape |
| « Vérifier la version en ligne » | La zone DNS n'est pas encore propagée, ou le certificat n'est pas délivré | Attendre, puis relancer |

## Geste 5 : lancer « Vérifier l'étape 1 »

**Pourquoi à la main.** Ce contrôle clôt l'étape, et c'est à vous d'en lire le
résultat. Il n'accompagne pas chaque déploiement, parce qu'il écrit dans la
base et dans le bucket des états.

**Ce qu'il faut faire.**

```sh
gh workflow run verify.yml --ref main
gh run watch
```

Ouvrez ensuite la page de l'exécution : son résumé contient le tableau
« Vérification de l'étape 1 ».

**Ce que le geste crée et coûte.** Rien de durable : deux lignes témoins
écrites puis effacées dans la base, et un objet d'essai écrit puis supprimé
dans le bucket, dont le versionnement garde quelques octets.

**Comment vérifier.** Les six lignes du tableau doivent indiquer « Réussi ».

| Ligne du tableau | Ce qu'elle établit |
| --- | --- |
| « Rôles SQL sans privilège excessif » | Les cinq rôles existent sur la base managée, sans `SUPERUSER` ni `BYPASSRLS`. |
| « Extension pgvector et index HNSW » | La version de pgvector, donnée dans le détail, et la création d'un index sur 1024 dimensions. |
| « Cloisonnement par tenant et sauvegarde » | Chaque tenant ne voit que sa ligne de la table témoin, et la sauvegarde par `pg_dump` lit pourtant les deux. |
| « Schéma de la file de tâches » | Le schéma `pgboss` appartient au rôle `queue`. |
| « Verrou de l'état » | Le bucket refuse une deuxième écriture conditionnelle : deux applications ne peuvent pas modifier l'état en même temps. |
| « Plan sans changement » | OpenTofu ne propose plus rien : l'infrastructure correspond à sa description. |

La ligne qui précède le tableau donne la version de PostgreSQL. Le journal de
l'étape « Contrôler la base depuis l'instance » contient le rapport complet :
les attributs du compte `avnadmin` et de chaque rôle, et le message par lequel
`pg_dump` refuse une sauvegarde sans `--enable-row-security`.

L'étape 1 est acquise quand ce tableau est entièrement réussi et qu'une
nouvelle fusion dans `main` se déploie sans geste.

## Par la suite

**Relancer `scripts/bootstrap.sh`.** La commande se relance à tout moment. Il
lui faut de nouveaux identifiants personnels, créés puis révoqués comme au
geste 3, et la phrase de passe dans `STATE_PASSPHRASE`. Elle relit alors son
état dans le bucket, et OpenTofu ne propose aucun changement si rien n'a bougé.

**Renouveler le compte de service et la clé S3.** Dans les mêmes conditions,
`scripts/bootstrap.sh rotate` remplace le compte de service de la CI et la clé
S3, puis met à jour les secrets du dépôt. OpenTofu annonce alors
`Plan: 2 to add, 1 to change, 2 to destroy.` Ne lancez aucun workflow pendant
ce temps. La commande ne touche ni à la phrase de passe, ni aux mots de passe
des rôles SQL, ni aux clés SSH. Si elle s'arrête après `Apply complete!`,
relancez `scripts/bootstrap.sh` sans `rotate` : le renouvellement est fait, il
reste à inscrire les secrets et à ranger l'état. Relancée avec `rotate`, elle
renouvellerait tout une seconde fois.

**Lire les journaux du service.** Ils restent sur l'instance, dans Docker, à
raison de cinq fichiers de 10 Mo au plus par conteneur. Avec une clé
d'administration (étape 3.1) : `ssh ops@preview.memoire.example.com`, puis
`sudo docker ps` et `sudo docker logs --tail 200 <conteneur>`.

**Revenir à une version précédente.** Annulez le commit fautif avec
`git revert`, puis fusionnez : le déploiement remet l'ancien code en service.
Les migrations déjà jouées ne sont pas défaites.

## Ce qui reste à vérifier sur les services réels

Tout ce qui pouvait l'être a été essayé sans compte : les workflows par
actionlint, puis étape par étape sur un poste, avec de fausses commandes à la
place des services ; les scripts avec le vrai OpenTofu face à un émulateur de
l'API d'OVHcloud ; l'instance dans un conteneur. La liste qui suit est ce que
seuls les services réels peuvent confirmer. `infra/README.md` détaille les
points d'infrastructure et leurs remèdes.

Pendant le geste 3 :

- la création du compte de service et de la politique IAM avec des identifiants
  personnels, et l'acceptation par OVHcloud des 35 noms d'actions de la
  politique ;
- la présence d'un vRack sur le projet ;
- le droit, pour la clé S3, d'écrire dans un bucket dont son utilisateur n'est
  pas propriétaire, et le délai après lequel une clé neuve est acceptée ;
- le point d'accès inscrit dans `STATE_ENDPOINT`, à comparer à celui que
  l'espace client affiche pour le bucket ;
- à une relance, la relecture de la clé S3 par l'API, et pour `rotate` la
  suppression d'un compte de service encore cité par une politique ;
- les libellés exacts du formulaire de création des identifiants, que cette
  page décrit sans avoir pu l'afficher ;
- la commande sous macOS : elle a été essayée avec bash 3.2, celui de macOS,
  mais sur un poste Linux.

Des identifiants personnels aux droits plus étroits devraient suffire, mais
n'ont pas été essayés : `GET`, `POST`, `PUT` et `DELETE` sur
`/me/api/oauth2/client*`, `/iam/policy*`,
`/cloud/project/<identifiant du projet>*` et
`/publicCloud/project/<identifiant du projet>/*`, et `GET` sur `/auth/details`
et `/domain/zone/<zone>`.

Pendant le premier déploiement :

- l'exécution sur GitHub des workflows qui touchent à OVHcloud, qui n'a jamais
  eu lieu : seule l'intégration continue y a tourné, sans son job « Plan de la
  préversion ». Restent à voir leurs conditions une fois `OVH_BOOTSTRAPPED`
  posée, et la première publication de l'image par le jeton du workflow ;
- l'authentification d'OpenTofu par le compte de service, et la suffisance des
  35 actions : une erreur 403 nomme l'action manquante ;
- la disponibilité, dans le projet, de la région `GRA11`, de l'image
  « Ubuntu 24.04 », du gabarit `d2-2`, et de l'offre `essential` en `db1-4`
  pour PostgreSQL 17 sur un réseau privé. Une région manquante s'ajoute dans
  « Gestion du projet », onglet « Localisations ». Le catalogue public
  proposait encore cette offre le 11 novembre 2026, mais OVHcloud renouvelle sa
  gamme de bases managées : `infra/README.md` dit quoi changer si elle est
  refusée ;
- les durées réelles de création de la base et de l'instance ;
- le premier démarrage d'une vraie instance : installation de Docker, pare-feu,
  canal de déploiement prêt en moins de dix minutes, et création du compte
  `ops` quand des clés d'administration sont fournies ;
- l'acceptation par OVHcloud des données d'initialisation de l'instance, qui
  pèsent environ 31 ko pour une limite de 65 535 octets, et la règle qui
  interdit aux conteneurs de lire les métadonnées de l'instance ;
- le téléchargement de l'image par l'instance, avec le jeton du workflow, et
  celui de l'image de Caddy depuis Docker Hub ;
- la délivrance du certificat par Let's Encrypt, seule autorité que Caddy
  sollicite, et HTTP/3 sur le port UDP 443 ;
- la connexion du service à la base par le réseau privé, avec vérification de
  son certificat.

Pendant « Amorcer la base » :

- l'obtention d'un jeton par le compte de service, et les routes qui
  réinitialisent le mot de passe d'`avnadmin`, lues dans le schéma de l'API ;
- le droit, pour `avnadmin`, de créer les rôles et l'extension `vector`, et le
  fait qu'il soit propriétaire de la base `memoire` ;
- l'effet, sur les comptes que la plateforme réserve à sa supervision, du
  retrait des droits de `PUBLIC` sur la base `memoire` ;
- le nombre de connexions que le service accorde : les limites des cinq rôles
  en totalisent 46.

Pendant « Vérifier l'étape 1 » :

- les quatre points de l'étape, que le tableau établit ;
- l'écriture conditionnelle par l'AWS CLI du runner, essayée ici avec l'AWS CLI
  2.40, mais face à un serveur S3 local ;
- un second plan vide. `infra/README.md` nomme les attributs qui pourraient
  créer un écart permanent.

À observer ensuite :

- la première facture : tarif de l'instance, facturation de l'adresse IPv4 et
  lignes de la base ;
- les mises à jour nocturnes de l'instance, et son redémarrage éventuel à
  3 h 30 UTC ;
- la mémoire de l'instance, que se partagent trois conteneurs limités à 512,
  384 et 128 Mio, et la reprise du worker après une coupure du réseau vers la
  base ;
- les pull requests de Dependabot. D'après sa documentation, il ne suit dans
  les workflows que les actions : ni l'image du conteneur de service de
  `ci.yml`, ni les images de shellcheck et d'actionlint, ni la version
  d'OpenTofu. Ces versions se montent à la main. Il suit l'image de base du
  `Dockerfile`, écrite pour cela dans une instruction `FROM`, et les images des
  fichiers Compose. Quand il propose une nouvelle image de base, montez
  `.node-version` dans la même pull request.

## Gestes des étapes suivantes

Ils ne sont que listés ici ; chacun sera décrit avec son étape.

- Étape 2 : créer l'application OAuth GitHub qui sert à la connexion, une par
  environnement.
- Étape 2 : ajouter le connecteur dans l'assistant qui interrogera le service.
- Étape 4 : créer une clé AI Endpoints dans l'espace client, et la renouveler à
  son expiration.
- Demander à OVHcloud l'option qui réserve l'exploitation du service à ses
  entités européennes.
- Tous les 90 jours, renouveler les secrets. `scripts/bootstrap.sh rotate`
  couvre dès maintenant le compte de service et la clé S3.
- En cas de sinistre, lancer le script versionné de restauration, qui crée une
  nouvelle base à réimporter dans le code. Il sera livré avec les sauvegardes.
