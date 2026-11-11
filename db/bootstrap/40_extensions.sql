-- Extensions : pgvector pour la recherche vectorielle, pg_trgm et unaccent pour
-- la recherche plein texte en français.
--
-- Elles sont créées ici, par le compte d'administration, parce que le rôle des
-- migrations n'en a pas le droit. Le schéma public les rend visibles de tous
-- les rôles sans toucher à leur search_path.

create extension if not exists vector with schema public;
create extension if not exists pg_trgm with schema public;
create extension if not exists unaccent with schema public;
