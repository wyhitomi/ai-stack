#!/bin/bash
# Runs once, on the first start of an empty data directory.
# One database + one least-privilege role per service.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username postgres <<SQL
CREATE ROLE litellm   LOGIN PASSWORD '${LITELLM_DB_PASSWORD}';
CREATE ROLE hindsight LOGIN PASSWORD '${HINDSIGHT_DB_PASSWORD}';

CREATE DATABASE litellm   OWNER litellm;
CREATE DATABASE hindsight OWNER hindsight;
SQL

# Extensions need superuser: create them up-front in the hindsight DB.
psql -v ON_ERROR_STOP=1 --username postgres --dbname hindsight <<SQL
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
SQL
