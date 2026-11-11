-- Rôles SQL de l'application : un par usage, aucun ne peut contourner la
-- sécurité par ligne (RLS).
--
--   app       le serveur, soumis aux politiques RLS de chaque tenant
--   auth      le serveur d'autorisation (étape 2)
--   queue     le worker et sa file pg-boss
--   backup    la sauvegarde logique, seule à lire tous les tenants
--   migrator  les migrations, propriétaire des schémas de l'application
--
-- Le job db-bootstrap fournit chaque mot de passe dans un paramètre de session
-- memoire_bootstrap.password_<rôle>, sous la forme d'un vérificateur
-- SCRAM-SHA-256 que PostgreSQL enregistre tel quel.

do $roles$
declare
  spec record;
  secret text;
begin
  for spec in
    select *
    from (values
      -- Ensemble, les limites de connexions restent sous la centaine qu'offre
      -- un PostgreSQL managé de 4 Go, et laissent deux instances du service
      -- cohabiter le temps d'un déploiement.
      ('app', 20, '15s'),
      ('auth', 10, '5s'),
      ('queue', 10, '60s'),
      -- pg_dump lève lui-même ce délai dans sa session : il ne borne que les
      -- autres requêtes du rôle.
      ('backup', 3, '60s'),
      ('migrator', 3, '15min')
    ) as roles (name, connection_limit, statement_timeout)
  loop
    secret := current_setting('memoire_bootstrap.password_' || spec.name, true);
    if secret is null or secret = '' then
      raise exception 'le paramètre de session memoire_bootstrap.password_% est absent', spec.name;
    end if;

    if not exists (select from pg_catalog.pg_roles where rolname = spec.name) then
      execute format(
        'create role %I login nosuperuser nocreatedb nocreaterole noreplication nobypassrls',
        spec.name
      );
    end if;

    -- Un compte d'administration qui n'est pas superutilisateur ne peut pas
    -- nommer SUPERUSER ni BYPASSRLS dans ALTER ROLE, même pour les retirer :
    -- ces attributs sont posés à la création et contrôlés par 90_checks.sql.
    execute format(
      'alter role %I login connection limit %s password %L',
      spec.name, spec.connection_limit, secret
    );
    execute format('alter role %I set statement_timeout = %L', spec.name, spec.statement_timeout);
    -- Une transaction oubliée ouverte bloque le nettoyage des tables.
    execute format('alter role %I set idle_in_transaction_session_timeout = %L', spec.name, '60s');
  end loop;
end
$roles$;
