"""Cria o schema "coursegen" no Neon e o role de acesso da aplicação.

Uso:
    python db/apply_schema.py            # aplica schema.sql e cria o role, se faltar
    python db/apply_schema.py --rotate   # também gera uma senha nova para o role

Conecta com NEON_DATABASE_URL (owner) e grava a string de conexão do role
da aplicação em COURSEGEN_DATABASE_URL no .env. O role "coursegen_app"
só lê e escreve dados no schema "coursegen"; não cria nem altera tabelas
e não enxerga os demais schemas do banco.
"""

import secrets
import sys
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit

import psycopg2
from dotenv import dotenv_values

ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = ROOT / ".env"
SCHEMA_SQL = Path(__file__).with_name("schema.sql")

SCHEMA = "coursegen"
APP_ROLE = "coursegen_app"
ENV_KEY = "COURSEGEN_DATABASE_URL"

GRANTS_SQL = f"""
REVOKE ALL ON SCHEMA {SCHEMA} FROM PUBLIC;
GRANT USAGE ON SCHEMA {SCHEMA} TO {APP_ROLE};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {SCHEMA} TO {APP_ROLE};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA {SCHEMA} TO {APP_ROLE};
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA {SCHEMA} TO {APP_ROLE};
ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {APP_ROLE};
ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}
  GRANT USAGE, SELECT ON SEQUENCES TO {APP_ROLE};
ALTER DEFAULT PRIVILEGES IN SCHEMA {SCHEMA}
  GRANT EXECUTE ON FUNCTIONS TO {APP_ROLE};
-- Dados de referência são somente leitura para a aplicação.
REVOKE INSERT, UPDATE, DELETE ON {SCHEMA}.bloom_levels FROM {APP_ROLE};
-- Trilha de auditoria é append-only.
REVOKE UPDATE, DELETE ON {SCHEMA}.audit_log FROM {APP_ROLE};
ALTER ROLE {APP_ROLE} SET search_path = {SCHEMA}, public;
"""


def app_url(owner_url: str, password: str) -> str:
    parts = urlsplit(owner_url)
    host = parts.netloc.rsplit("@", 1)[1]
    netloc = f"{APP_ROLE}:{quote(password, safe='')}@{host}"
    return urlunsplit(parts._replace(netloc=netloc))


def write_env(key: str, value: str) -> None:
    lines = ENV_PATH.read_text(encoding="utf-8").splitlines()
    entry = f'{key}="{value}"'
    for i, line in enumerate(lines):
        if line.startswith(f"{key}="):
            lines[i] = entry
            break
    else:
        lines += ["", "# Acesso da aplicação CourseGen Studio (role coursegen_app, schema coursegen).", entry]
    ENV_PATH.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    rotate = "--rotate" in sys.argv
    env = dotenv_values(ENV_PATH)
    owner_url = env["NEON_DATABASE_URL"]

    conn = psycopg2.connect(owner_url)
    try:
        with conn, conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_roles WHERE rolname = %s", (APP_ROLE,))
            role_exists = cur.fetchone() is not None

            password = None
            if not role_exists or rotate or not env.get(ENV_KEY):
                password = secrets.token_urlsafe(32)
                verb = "ALTER" if role_exists else "CREATE"
                cur.execute(f"{verb} ROLE {APP_ROLE} WITH LOGIN PASSWORD %s", (password,))

            cur.execute(SCHEMA_SQL.read_text(encoding="utf-8"))
            cur.execute(GRANTS_SQL)

        if password:
            write_env(ENV_KEY, app_url(owner_url, password))
            print(f"Role {APP_ROLE} {'atualizado' if role_exists else 'criado'}; {ENV_KEY} gravado no .env.")
        else:
            print(f"Role {APP_ROLE} já existia; senha mantida.")
        print(f"Schema {SCHEMA} aplicado.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
