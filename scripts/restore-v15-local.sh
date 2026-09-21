#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.v15-local.yml"
DUMP_FILE="${ROOT_DIR}/sites/erpnext-db-1_dump.sql"
SITE_CONFIG="${ROOT_DIR}/sites/site_config.json"

cd "${ROOT_DIR}"

if [[ ! -f "${DUMP_FILE}" ]]; then
  echo "Missing dump: ${DUMP_FILE}"
  exit 1
fi

if [[ ! -f "${SITE_CONFIG}" ]]; then
  echo "Missing site config: ${SITE_CONFIG}"
  exit 1
fi

DB_NAME="$(python3 -c 'import json; print(json.load(open("'"${SITE_CONFIG}"'"))["db_name"])')"
DB_USER="${DB_NAME}"
DB_PASS="$(python3 -c 'import json; print(json.load(open("'"${SITE_CONFIG}"'"))["db_password"])')"
ROOT_PASS="$(grep '^DB_PASSWORD=' .env | cut -d= -f2-)"

echo "Starting MariaDB..."
docker compose -f "${COMPOSE_FILE}" up -d db

echo "Waiting for MariaDB to become healthy..."
for _ in $(seq 1 90); do
  status="$(docker compose -f "${COMPOSE_FILE}" ps db --format '{{.Health}}' 2>/dev/null || true)"
  if [[ "${status}" == "healthy" ]]; then
    break
  fi
  sleep 2
done

if [[ "$(docker compose -f "${COMPOSE_FILE}" ps db --format '{{.Health}}' 2>/dev/null || true)" != "healthy" ]]; then
  echo "MariaDB did not become healthy in time."
  exit 1
fi

echo "Creating database and site user..."
docker compose -f "${COMPOSE_FILE}" exec -T db mysql -uroot -p"${ROOT_PASS}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

if docker compose -f "${COMPOSE_FILE}" exec -T db mysql -uroot -p"${ROOT_PASS}" -Nse \
  "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" | grep -qx '0'; then
  echo "Importing dump into ${DB_NAME}..."
  docker compose -f "${COMPOSE_FILE}" exec -T db mysql -uroot -p"${ROOT_PASS}" "${DB_NAME}" < "${DUMP_FILE}"
else
  echo "Database ${DB_NAME} already has tables; skipping import."
fi

echo "Starting full v15 stack..."
docker compose -f "${COMPOSE_FILE}" up -d

echo
echo "Local v15 copy is starting on http://localhost:8080"
echo "Useful checks:"
echo "  docker compose -f docker-compose.v15-local.yml logs -f web"
echo "  docker compose -f docker-compose.v15-local.yml exec -u frappe web bench --site frontend list-apps"
