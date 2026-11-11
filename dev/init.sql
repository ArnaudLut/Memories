-- Reproduit en local ce que le PostgreSQL managé d'OVHcloud fournit avant tout
-- amorçage : un compte d'administration « avnadmin » qui n'est pas
-- superutilisateur, et la base « memoire » dont il est propriétaire.
--
-- Ce fichier est joué une seule fois par le superutilisateur local, qui tient
-- ici le rôle de la plateforme :
--   - par l'image PostgreSQL à la création du volume (dev/compose.yaml) ;
--   - en CI, par psql, sur le conteneur de service :
--       psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U postgres -d postgres -f dev/init.sql
-- Le mot de passe d'avnadmin vient de la variable DB_ADMIN_PASSWORD.

\getenv admin_password DB_ADMIN_PASSWORD

-- Les attributs sont ceux que la documentation d'OVHcloud donne pour avnadmin.
create role avnadmin login createdb createrole replication password :'admin_password';

-- Sur OVHcloud, avnadmin installe pgvector grâce à la liste d'extensions que la
-- plateforme autorise. L'image locale n'a pas ce mécanisme et pgvector n'est pas
-- une extension « trusted » : seul un superutilisateur peut l'installer.
-- L'extension est donc posée dans template1, et toute base créée ensuite la
-- contient déjà, y compris celles que les tests créent avec avnadmin.
\connect template1
create extension vector with schema public;

\connect postgres
create database memoire owner avnadmin;
