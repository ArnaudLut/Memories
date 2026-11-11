-- Accès à la base : seuls les rôles de l'application s'y connectent.
--
-- Par défaut, PostgreSQL laisse tout rôle se connecter à toute base et y créer
-- des objets temporaires. Ces droits sont retirés à PUBLIC, puis la connexion
-- est rendue aux cinq rôles. Le propriétaire de la base garde les siens.

do $database$
begin
  execute format('revoke all on database %I from public', current_database());
  execute format(
    'grant connect on database %I to app, auth, queue, backup, migrator',
    current_database()
  );
end
$database$;

-- Sans effet sur une base créée par PostgreSQL 15 ou plus récent, où PUBLIC
-- n'a déjà plus ce droit ; nécessaire si la base vient d'un modèle plus ancien.
revoke create on schema public from public;
