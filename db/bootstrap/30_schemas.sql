-- Schémas de l'application et leurs propriétaires.
--
--   app, auth, meta   à migrator : les migrations y posent tables, droits et
--                     politiques RLS (meta porte le journal des migrations)
--   pgboss            à queue : pg-boss y installe et fait évoluer ses tables
--
-- Créer un schéma au nom d'un autre rôle exige de pouvoir prendre ce rôle
-- (SET ROLE). Le compte d'administration s'accorde donc cette faculté le temps
-- de la création, puis la retire.

grant migrator, queue to current_user with set true, inherit false;

create schema if not exists app authorization migrator;
create schema if not exists auth authorization migrator;
create schema if not exists meta authorization migrator;
create schema if not exists pgboss authorization queue;

-- Retire toute appartenance aux cinq rôles que le compte d'administration s'est
-- accordée : celle qui précède, et celles que le service lui donne à la
-- création d'un rôle quand createrole_self_grant est réglé. Il ne lui reste
-- que l'option ADMIN, attachée au fait d'avoir créé ces rôles : ses sessions
-- n'héritent d'aucun droit sur les données.
do $memberships$
declare
  granted record;
begin
  for granted in
    select r.rolname
    from pg_catalog.pg_auth_members m
    join pg_catalog.pg_roles r on r.oid = m.roleid
    join pg_catalog.pg_roles me on me.oid = m.member and me.oid = m.grantor
    where me.rolname = current_user
      and r.rolname in ('app', 'auth', 'queue', 'backup', 'migrator')
  loop
    execute format('revoke %I from current_user', granted.rolname);
  end loop;
end
$memberships$;
