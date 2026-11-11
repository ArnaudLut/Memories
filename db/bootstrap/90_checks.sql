-- Contrôle de l'état final. L'amorçage échoue ici plutôt que de laisser une
-- base à moitié protégée.
--
-- Le compte d'administration n'est pas superutilisateur : quand un droit lui
-- manque, PostgreSQL répond parfois par un simple avertissement, par exemple à
-- un REVOKE sur une base dont il n'est pas propriétaire. Seul l'état constaté
-- fait donc foi.

do $checks$
declare
  problems text[] := '{}';
  expected record;
begin
  -- Les cinq rôles existent, se connectent et n'ont aucun attribut privilégié.
  for expected in
    select wanted.name, r.oid, r.rolcanlogin, r.rolsuper, r.rolbypassrls,
           r.rolcreatedb, r.rolcreaterole, r.rolreplication
    from unnest(array['app', 'auth', 'queue', 'backup', 'migrator']) as wanted (name)
    left join pg_catalog.pg_roles r on r.rolname = wanted.name
  loop
    if expected.oid is null then
      problems := problems || format('le rôle %s manque', expected.name);
    elsif not expected.rolcanlogin or expected.rolsuper or expected.rolbypassrls
      or expected.rolcreatedb or expected.rolcreaterole or expected.rolreplication then
      problems := problems || format('le rôle %s a un attribut inattendu', expected.name);
    elsif not has_database_privilege(expected.name, current_database(), 'CONNECT') then
      problems := problems || format('le rôle %s ne peut pas se connecter à la base', expected.name);
    end if;
  end loop;

  if has_database_privilege('public', current_database(), 'CONNECT') then
    problems := problems || format(
      'PUBLIC peut encore se connecter à la base %s, dont le propriétaire est %s',
      current_database(),
      (select pg_catalog.pg_get_userbyid(datdba) from pg_catalog.pg_database
       where datname = current_database())
    );
  end if;

  if has_schema_privilege('public', 'public', 'CREATE') then
    problems := problems || 'PUBLIC peut encore créer des objets dans le schéma public'::text;
  end if;

  for expected in
    select wanted.name, wanted.owner, pg_catalog.pg_get_userbyid(n.nspowner) as actual
    from (values
      ('app', 'migrator'),
      ('auth', 'migrator'),
      ('meta', 'migrator'),
      ('pgboss', 'queue')
    ) as wanted (name, owner)
    left join pg_catalog.pg_namespace n on n.nspname = wanted.name
  loop
    if expected.actual is distinct from expected.owner then
      problems := problems || format(
        'le schéma %s appartient à %s au lieu de %s',
        expected.name, coalesce(expected.actual, 'personne'), expected.owner
      );
    end if;
  end loop;

  for expected in
    select wanted.name
    from unnest(array['vector', 'pg_trgm', 'unaccent']) as wanted (name)
    where not exists (select from pg_catalog.pg_extension e where e.extname = wanted.name)
  loop
    problems := problems || format('l''extension %s manque', expected.name);
  end loop;

  if cardinality(problems) > 0 then
    raise exception 'amorçage incomplet : %', array_to_string(problems, ' ; ');
  end if;
end
$checks$;
