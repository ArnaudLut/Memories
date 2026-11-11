-- Socle de l'isolation entre tenants et table témoin.
--
-- Chaque table métier portera un tenant_id protégé par une politique RLS
-- forcée. Cette migration pose le contexte de tenant, les droits communs aux
-- tables du schéma app, et une table témoin qui sert de canari permanent aux
-- tests d'isolation et de sauvegarde.

grant usage on schema app to app, backup;

-- Le journal des migrations se lit sans s'écrire : le service annonce la
-- dernière migration sur /health, et la sauvegarde emporte le journal avec les
-- données qu'il décrit.
grant usage on schema meta to app, backup;
grant select on meta.schema_migrations to app, backup;

-- Tenant de la transaction en cours, posé par le service avec
-- set_config('app.tenant_id', ..., true). Sans contexte, le résultat est nul et
-- aucune ligne n'est visible. Le nullif couvre la chaîne vide que PostgreSQL
-- laisse dans la session une fois la transaction terminée.
create function app.current_tenant_id() returns uuid
  language sql
  stable
  return nullif(current_setting('app.tenant_id', true), '')::uuid;

-- Droits de toute table que les migrations créeront dans le schéma app. La
-- table témoin les reçoit par ce mécanisme, comme celles qui suivront. Pas de
-- TRUNCATE pour app : cette commande échappe à la RLS.
alter default privileges in schema app
  grant select, insert, update, delete on tables to app;
alter default privileges in schema app
  grant select on tables to backup;
-- Les séquences des colonnes serial et identity suivent leurs tables : app en
-- tire des valeurs, backup en lit l'état pour pg_dump.
alter default privileges in schema app
  grant usage on sequences to app;
alter default privileges in schema app
  grant select on sequences to backup;

create table app.rls_witness (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null,
  note text not null,
  created_at timestamptz not null default now()
);

-- FORCE soumet aussi le propriétaire de la table aux politiques : aucun rôle de
-- l'application ne lit les lignes d'un tenant sans politique qui l'y autorise.
alter table app.rls_witness enable row level security;
alter table app.rls_witness force row level security;

create policy tenant_isolation on app.rls_witness
  for all
  to app
  using (tenant_id = app.current_tenant_id())
  with check (tenant_id = app.current_tenant_id());

-- Seule exception : la sauvegarde lit tous les tenants, sans pouvoir écrire.
create policy backup_read on app.rls_witness
  for select
  to backup
  using (true);
