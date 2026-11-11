# Infrastructure

Ce répertoire décrit l'infrastructure OVHcloud du service avec OpenTofu
(`~> 1.13.0`) et le fournisseur `ovh/ovh` en version `2.24.0`. Les versions des
fournisseurs sont figées par un fichier `.terraform.lock.hcl` dans chaque
racine.

## Comment les piles s'articulent

| Répertoire | Qui l'applique | Ce qu'il gère |
| --- | --- | --- |
| `bootstrap/` | Le fondateur, une fois, avec ses identifiants personnels, par `scripts/bootstrap.sh` | Le compte de service de la CI, sa politique IAM, le bucket des états et la clé S3 qui y donne accès |
| `envs/preview/` | La CI, avec le compte de service | Le réseau privé, l'instance, la base PostgreSQL managée et l'enregistrement DNS de la préversion |
| `envs/production/` | Personne avant la fin de l'étape 2 | Les mêmes ressources pour la production, seulement validées et testées d'ici là |
| `modules/` | | Les quatre modules communs aux deux environnements : `network`, `instance`, `database`, `dns` |
| `policy/` | La CI, avant toute application | Le garde-fou qui refuse un plan destructeur |

Le projet Public Cloud est créé à la main. La pile `bootstrap` le lit sans le
gérer : aucune pile ne peut donc le résilier.

Les deux racines d'environnement partagent des fichiers identiques. Tout ce qui
les distingue tient dans `environment.tf` : la clé de l'état, le nom de
l'environnement, le gabarit de l'instance, le sous-réseau privé et son VLAN. Un
test de la racine de production échoue si un autre fichier diverge.

Les trois états vivent dans le même bucket, sous les clés
`bootstrap/terraform.tfstate`, `preview/terraform.tfstate` et
`production/terraform.tfstate`. Trois protections s'y appliquent :

- l'état et les plans sont chiffrés sur la machine qui les produit, avec la
  phrase de passe de la variable `state_passphrase` ;
- le verrou est un objet `<clé>.tflock` écrit de façon conditionnelle
  (`use_lockfile`), sans table annexe. Quand une exécution interrompue l'a
  laissé en place, le workflow « Lever le verrou de l'état » le retire
  (`BOOTSTRAP.md`) ;
- la clé S3 remise à la CI ne donne accès qu'à ce bucket.

Les sorties de `bootstrap` alimentent les secrets et les variables du dépôt ;
`BOOTSTRAP.md`, à la racine du dépôt, décrit cette étape.

## Vérifier sans compte OVHcloud

Ces commandes n'appellent pas OVHcloud et ne demandent ni identifiant ni phrase
de passe. Les racines d'environnement lisent `deploy/cloud-init.yaml.tftpl` et
`deploy/host/memoire-deploy`.

```sh
tofu fmt -check -recursive infra
python3 -m unittest discover -s infra/policy/tests
```

Puis, toujours depuis la racine du dépôt, pour chacune des trois piles :

```sh
for root in infra/bootstrap infra/envs/preview infra/envs/production; do
  tofu -chdir="$root" init -backend=false -input=false -lockfile=readonly \
    && tofu -chdir="$root" validate \
    && tofu -chdir="$root" test || break
done
```

La boucle s'arrête à la première pile en échec ; chacune doit finir sur une
ligne `Success!`.

Les tests utilisent un fournisseur OVHcloud simulé. Ceux des quatre modules
sont rangés dans `envs/preview/tests`.

`tofu validate` accepte sans message une clé inconnue dans les objets passés
aux attributs `networks`, `rule`, `versioning` et `encryption`, et l'ignore.
Dans `networks` et `rule`, une clé facultative mal orthographiée passe donc
inaperçue. Les tests vérifient la valeur de chaque clé attendue ; toute
nouvelle clé doit recevoir le sien.

## Planifier en local

Un plan local prend le verrou de l'état pendant sa durée : mieux vaut ne pas en
lancer pendant qu'un job de la CI tourne. Aucune valeur ne doit être écrite
dans un fichier du dépôt.

Seule la phrase de passe se trouve dans le gestionnaire de mots de passe du
fondateur. Les autres valeurs se retrouvent ainsi :

- les variables du dépôt, par `gh variable list` ;
- la clé S3 du bucket des états, que GitHub ne permet pas de relire, par la
  console de l'API (`https://api.eu.ovhcloud.com/console/`), en trois appels :
  `GET /cloud/project/{serviceName}/user` donne l'identifiant de l'utilisateur
  décrit comme `memoire-state`,
  `GET /cloud/project/{serviceName}/user/{userId}/s3Credentials` sa clé
  d'accès, et
  `POST /cloud/project/{serviceName}/user/{userId}/s3Credentials/{access}/secret`
  sa clé secrète ;
- le compte de service, par l'état de `bootstrap`, que la clé S3 et la phrase
  de passe suffisent à lire.

Depuis la racine du dépôt, en quatre temps. Les blocs ne contiennent aucun
commentaire : dans un terminal, zsh, le shell par défaut de macOS, ne
reconnaît pas les commentaires et en exécuterait le texte.

1. Le bucket des états, d'après les variables du dépôt :

   ```sh
   variable() { gh variable list --json name,value --jq ".[] | select(.name == \"$1\") | .value"; }
   export STATE_BUCKET=$(variable STATE_BUCKET)
   export STATE_REGION=$(variable STATE_REGION)
   export STATE_ENDPOINT=$(variable STATE_ENDPOINT)
   ```

2. La clé d'accès S3, sa clé secrète, puis la phrase de passe. Lancez ces
   commandes une par une : chacune attend que vous colliez la valeur puis que
   vous appuyiez sur Entrée, sans l'afficher ni l'écrire dans l'historique.

   ```sh
   read -rs AWS_ACCESS_KEY_ID && export AWS_ACCESS_KEY_ID
   ```

   ```sh
   read -rs AWS_SECRET_ACCESS_KEY && export AWS_SECRET_ACCESS_KEY
   ```

   ```sh
   read -rs TF_VAR_state_passphrase && export TF_VAR_state_passphrase
   ```

3. Le compte de service, lu dans l'état de `bootstrap` sans être affiché :

   ```sh
   scripts/ci/tofu-init.sh infra/bootstrap
   export OVH_ENDPOINT=ovh-eu
   export OVH_CLIENT_ID=$(tofu -chdir=infra/bootstrap output -raw ci_client_id)
   export OVH_CLIENT_SECRET=$(tofu -chdir=infra/bootstrap output -raw ci_client_secret)
   ```

4. Les mêmes valeurs que dans les workflows, sans quoi le plan proposerait de
   modifier l'infrastructure, puis le plan et le garde-fou. La variable
   `ADMIN_SSH_PUBLIC_KEYS` est facultative : sans elle, les workflows passent
   une liste vide.

   ```sh
   export TF_VAR_project_id=$(variable OVH_PROJECT_ID)
   export TF_VAR_dns_zone=$(variable DNS_ZONE)
   export TF_VAR_hostname=$(variable PREVIEW_HOSTNAME)
   export TF_VAR_acme_email=$(variable ACME_EMAIL)
   keys=$(variable ADMIN_SSH_PUBLIC_KEYS)
   export TF_VAR_admin_ssh_public_keys="${keys:-[]}"
   scripts/ci/tofu-init.sh infra/envs/preview
   tofu -chdir=infra/envs/preview plan -input=false -out=plan.tfplan \
     && tofu -chdir=infra/envs/preview show -json plan.tfplan > infra/envs/preview/plan.json \
     && python3 infra/policy/check_plan.py infra/envs/preview/plan.json
   ```

Les deux fichiers s'écrivent dans `infra/envs/preview`. `plan.tfplan` est
chiffré, mais `plan.json` contient les secrets en clair : git l'ignore.
Supprimez-le après usage, puis fermez le terminal : son environnement porte
les secrets.

`tofu output`, `tofu untaint` et `tofu force-unlock` n'ont besoin que du
bucket, de la clé S3 et de la phrase de passe : la préparation s'arrête alors
après les trois commandes `read`, suivies de
`scripts/ci/tofu-init.sh infra/envs/preview`. Ces trois commandes d'OpenTofu se
lancent ensuite depuis la racine du dépôt avec l'option
`-chdir=infra/envs/preview`, par exemple
`tofu -chdir=infra/envs/preview output`. Sans cette option, OpenTofu ne lit pas
l'état du bucket : `tofu untaint` répond que l'état ne contient aucune
ressource (`No such resource instance`), `tofu output` qu'il n'y a aucune
sortie (`No outputs found`), et `tofu force-unlock` qu'il ne peut pas lever un
verrou local (`Local state cannot be unlocked by another process`).

La pile `bootstrap` se planifie de la même façon, avec l'option
`-chdir=infra/bootstrap`, les identifiants personnels du fondateur
(`OVH_APPLICATION_KEY`, `OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`) à la
place du compte de service, et sans les variables `hostname` et `acme_email`.

## Le garde-fou

`policy/check_plan.py plan.json` lit la sortie de `tofu show -json`. Il sort
avec le code 1, en nommant les ressources fautives, dès qu'un plan supprime ou
remplace le service de base de données, la base, le bucket des états ou le
projet. Il sort avec le code 2 quand le fichier est illisible, et avec le code
0 sinon. Il n'affiche jamais de valeur.

Ce n'est qu'une des quatre protections de la base : s'y ajoutent
`prevent_destroy` dans le module, `deletion_protection` côté OVHcloud et une
politique IAM qui ne donne à la CI aucun droit de suppression sur le service ni
sur la base.

Le garde-fou signale aussi, sans refuser le plan, une instance dont le document
cloud-init change. OVHcloud réinstalle alors l'instance et efface son disque
racine, alors que le plan n'annonce qu'une modification sur place. C'est le cas
dès que changent le gabarit `deploy/cloud-init.yaml.tftpl`, la commande
`deploy/host/memoire-deploy`, les clés des administrateurs ou le dépôt
d'images.

## À vérifier à la première application réelle

Rien de ce qui suit n'a pu être essayé sans compte OVHcloud.

Pour `bootstrap` :

1. L'avertissement du contrôle `project_vrack` ne doit pas apparaître. S'il
   apparaît, le projet n'est rattaché à aucun vRack et les réseaux privés ne
   pourront pas être créés. Il faut alors commander un vRack, gratuit, dans la
   rubrique vRack de l'espace client, puis lui rattacher le projet depuis
   l'onglet des services attachés. Les projets récents en reçoivent un à leur
   création.
2. La sortie `state_endpoint` doit correspondre au point d'accès que l'espace
   client affiche pour le bucket.
3. La clé S3 doit pouvoir écrire dans un bucket dont son utilisateur n'est pas
   propriétaire : la migration de l'état vers le bucket le prouve.

Pour `envs/preview` :

1. La région `GRA11` doit être activée sur le projet. Sinon, la variable
   `compute_region` désigne une autre région de Gravelines ; elle doit commencer
   par `GRA`, comme la région de la base.
2. L'offre `essential` et le gabarit `db1-4` doivent être proposés à `GRA` pour
   PostgreSQL 17, avec un réseau privé. Le catalogue public les proposait
   encore le 11 novembre 2026, mais le guide de migration d'OVHcloud les range
   dans l'ancienne génération de ses bases managées. En cas de refus, le
   message d'erreur du fournisseur nomme le critère en cause et les valeurs
   disponibles. L'offre et le gabarit se changent alors par les variables
   `database_plan` et `database_flavor`, dans le fichier `variables.tf` des
   deux environnements, et le coût mensuel est à recalculer.
3. Après l'application, les sorties `instance_ipv4` et `database` doivent être
   renseignées : chacune échoue avec un message explicite si l'API ne renvoie
   pas exactement une adresse IPv4 publique ou un point d'accès `postgresql`.
4. Un second `tofu plan` lancé aussitôt doit être vide. Les candidats à un écart
   permanent sont l'ordre de `backup_regions`, le résolveur du sous-réseau,
   l'ordre des règles du groupe de sécurité et le libellé de la restriction
   d'adresses de la base.
5. Sur l'instance, la route par défaut doit rester celle de l'interface
   publique, et la base doit répondre sur son adresse privée.
6. Une erreur 403 pendant un plan ou une application nomme l'action IAM
   manquante : la liste fermée se trouve dans `bootstrap/main.tf`.

Si la création de la base échoue en cours de route, par exemple sur un délai
dépassé (le fournisseur attend 40 minutes), ou si l'exécution est annulée
pendant cette création, OpenTofu marque la base comme à remplacer. Le plan
suivant veut alors la détruire, ce que `prevent_destroy` refuse : l'étape
« Planifier et passer le garde-fou » échoue avec
`Resource instance cannot be destroyed`. Examinez le service dans l'espace
client, puis choisissez l'un de ces deux remèdes, sans jamais retirer la
protection du code :

- si le service est finalement prêt, levez la marque depuis un poste préparé
  comme dans « Planifier en local », où la clé S3 et la phrase de passe
  suffisent. Depuis la racine du dépôt :
  `tofu -chdir=infra/envs/preview untaint module.database.ovh_cloud_project_database.this` ;
- s'il est en erreur, ou pour éviter de préparer un poste, supprimez-le dans
  l'espace client, après avoir désactivé au besoin sa protection contre la
  suppression, et attendez qu'il ait disparu de la liste des bases : au plan
  suivant, OpenTofu constate son absence et propose de le créer.

Relancez ensuite le workflow « Déployer ».
