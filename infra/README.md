# Infrastructure

Ce répertoire décrit l'infrastructure OVHcloud du service avec OpenTofu
(`~> 1.13.0`) et le fournisseur `ovh/ovh` en version `2.24.0`. Les versions des
fournisseurs sont figées par un fichier `.terraform.lock.hcl` dans chaque
racine.

## Comment les piles s'articulent

| Répertoire | Qui l'applique | Ce qu'il gère |
| --- | --- | --- |
| `bootstrap/` | Le fondateur, une fois, avec ses identifiants personnels, par `scripts/bootstrap.sh` | Le compte de service de la CI, sa politique IAM, le bucket d'état et la clé S3 qui y donne accès |
| `envs/preview/` | La CI, avec le compte de service | Le réseau privé, l'instance, la base PostgreSQL managée et l'enregistrement DNS de la préversion |
| `envs/production/` | Personne avant la fin de l'étape 2 | Les mêmes ressources pour la production, seulement validées et essayées d'ici là |
| `modules/` | | Les quatre modules communs aux deux environnements : `network`, `instance`, `database`, `dns` |
| `policy/` | La CI, avant toute application | Le garde-fou qui refuse un plan destructeur |

Le projet Public Cloud est créé à la main. La pile `bootstrap` le lit sans le
gérer : aucune pile ne peut donc le résilier.

Les deux racines d'environnement partagent des fichiers identiques. Tout ce qui
les distingue tient dans `environment.tf` : la clé de l'état, le nom de
l'environnement, le gabarit de l'instance, le sous-réseau privé et son VLAN. Un
essai de la racine de production échoue si un autre fichier diverge.

Les trois états vivent dans le même bucket, sous les clés
`bootstrap/terraform.tfstate`, `preview/terraform.tfstate` et
`production/terraform.tfstate`. Trois protections s'y appliquent :

- l'état et les plans sont chiffrés sur la machine qui les produit, avec la
  phrase de passe de la variable `state_passphrase` ;
- le verrou est un objet `<clé>.tflock` écrit de façon conditionnelle
  (`use_lockfile`), sans table annexe ;
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

# À répéter dans infra/bootstrap, infra/envs/preview et infra/envs/production.
tofu init -backend=false -input=false -lockfile=readonly
tofu validate
tofu test
```

Les essais utilisent un fournisseur OVHcloud simulé. Ceux des quatre modules
sont rangés dans `envs/preview/tests`.

`tofu validate` ne contrôle pas les clés des objets passés aux attributs
`networks`, `rule`, `versioning` et `encryption` : une clé facultative mal
orthographiée y est ignorée sans message. Les essais vérifient donc la valeur
de ces clés ; toute nouvelle clé doit recevoir la sienne.

## Planifier en local

Un plan local prend le verrou de l'état pendant sa durée : mieux vaut ne pas en
lancer pendant qu'un travail de la CI tourne. Les valeurs viennent des sorties
de `bootstrap` et du gestionnaire de secrets du fondateur ; aucune ne doit être
écrite dans un fichier du dépôt.

```sh
cd infra/envs/preview

export OVH_ENDPOINT=ovh-eu
export OVH_CLIENT_ID=... OVH_CLIENT_SECRET=...           # compte de service
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...   # clé S3 du bucket d'état
export TF_VAR_state_passphrase=...
export TF_VAR_project_id=... TF_VAR_dns_zone=exemple.fr
export TF_VAR_hostname=preview.memoire.exemple.fr TF_VAR_acme_email=contact@exemple.fr

tofu init -input=false -lockfile=readonly \
  -backend-config="bucket=<state_bucket>" \
  -backend-config="region=<state_region>" \
  -backend-config='endpoints={s3="<state_endpoint>"}'
tofu plan -input=false -out=plan.tfplan
tofu show -json plan.tfplan > plan.json
python3 ../../policy/check_plan.py plan.json
```

`plan.tfplan` est chiffré, mais `plan.json` contient les secrets en clair : il
est ignoré par git et se supprime après usage. La variable
`TF_VAR_admin_ssh_public_keys` attend une liste JSON, par exemple
`'["ssh-ed25519 AAAA... nom"]'`.

La pile `bootstrap` se planifie de la même façon depuis `infra/bootstrap`, avec
les identifiants personnels du fondateur (`OVH_APPLICATION_KEY`,
`OVH_APPLICATION_SECRET`, `OVH_CONSUMER_KEY`) à la place du compte de service,
et sans les variables `hostname` et `acme_email`.

## Le garde-fou

`policy/check_plan.py plan.json` lit la sortie de `tofu show -json`. Il sort
avec le code 1, en nommant les ressources fautives, dès qu'un plan supprime ou
remplace le service de base de données, la base, le bucket d'état ou le projet.
Il sort avec le code 2 quand le fichier est illisible, et avec le code 0 sinon.
Il n'affiche jamais de valeur.

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
   PostgreSQL 17, avec un réseau privé. En cas de refus, le message d'erreur du
   fournisseur nomme le critère en cause et les valeurs disponibles.
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
dépassé, OpenTofu la marque comme à remplacer et le plan suivant veut la
détruire, ce que `prevent_destroy` refuse. Il faut alors examiner le service
dans l'espace client, puis lever la marque avec
`tofu untaint module.database.ovh_cloud_project_database.this`, sans jamais
retirer la protection.
