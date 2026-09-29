#!/usr/bin/env bash
# Roda os testes de banco num Postgres DESCARTÁVEL (o banco é apagado e recriado).
#   DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres npm run test:db
# Sem Supabase local: sobe um Postgres com
#   docker run -d --name pgteste -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16
# Nunca aponte para o banco de produção.
set -euo pipefail
: "${DATABASE_URL:?defina DATABASE_URL apontando para um Postgres descartável}"
case "$DATABASE_URL" in *supabase.co*) echo "Recusado: isto parece o Supabase de produção."; exit 1;; esac
DIR="$(cd "$(dirname "$0")" && pwd)"
ADMIN_URL="${DATABASE_URL%/*}/postgres"
psql "$ADMIN_URL" -q -v ON_ERROR_STOP=1 -c "drop database if exists financeiro_teste" -c "create database financeiro_teste" >/dev/null
URL="${DATABASE_URL%/*}/financeiro_teste"
psql "$URL" -q -v ON_ERROR_STOP=1 -f "$DIR/00-shim-supabase.sql" >/dev/null
for f in "$DIR"/../../supabase/migrations/*.sql; do psql "$URL" -q -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v NOTICE || true; done
psql "$URL" -v ON_ERROR_STOP=1 -f "$DIR/10-regras-de-negocio.sql"
