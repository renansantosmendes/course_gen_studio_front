# CLAUDE.md

## About this project

Front end of **CourseGen Studio** (SynapseAI Solutions), a tool for
generating and reviewing course material with AI. The back end lives in
the sibling repository `../course_gen_studio_backend`.

Current contents:

- `index.html`: entry point; redirects to `coursegen-landing.html`.
- `coursegen-landing.html`: marketing landing page.
- `coursegen-login.html`: login and password recovery.
- `coursegen-app.html`: the application (my courses, briefing,
  structure, lesson plan, assessment, library, sources, versions,
  exports, integrations).
- `db/schema.sql`: PostgreSQL schema of the product (Neon).
- `db/apply_schema.py`: applies the schema and creates the application
  role.

## About the HTML pages

- Each page is a single self-contained file: CSS in a `<style>` block
  and JavaScript in a `<script>` block in the same file. There is no
  build step, bundler or framework; keep it that way unless asked
  otherwise.
- Pages link to each other with relative paths, so the site works both
  opened from disk and served statically. Navigation flow: landing
  ("Entrar" / "Acessar o estúdio") -> login (`#recuperar` opens password
  recovery) -> app (on submit, while authentication is not connected);
  app logo -> landing, app "Sair" -> login; login logo -> landing. The
  app accepts a view in the hash (for example `coursegen-app.html#fontes`).
- The only external resource allowed is Google Fonts (IBM Plex Sans,
  IBM Plex Mono and Schibsted Grotesk). Do not add other CDNs or
  libraries without asking.
- All user-facing text is in Brazilian Portuguese (`lang="pt-BR"`).
- Keep the visual identity consistent across the three pages: reuse the
  existing fonts, colors (for example the `#103050` sidebar navy, the
  `#F5F7FA` background and the `#1B2430` text color) and component
  styles instead of introducing new ones.
- Screen and table names in the app must match the "screen to tables"
  map at the top of `db/schema.sql`. If a screen is added or renamed,
  update that map too.
- Do not use emojis in the interface.

## About the database (`db/`)

- Everything lives in the `coursegen` schema. The Neon database is
  shared with other projects (`public`, `pgl_auth`, `pgl_proxy`,
  `agent_conversations`); never create or change objects outside
  `coursegen`.
- `schema.sql` must stay idempotent (`CREATE ... IF NOT EXISTS`,
  `CREATE OR REPLACE`), so it can be run more than once.
- Apply the schema with `uv run python db/apply_schema.py`
  (add `--rotate` to generate a new password for the application role).
  It connects with `NEON_DATABASE_URL` (owner) and writes
  `COURSEGEN_DATABASE_URL` to `.env`.
- The application role `coursegen_app` only reads and writes data in
  `coursegen`. `bloom_levels` is read-only and `audit_log` is
  append-only for it. When adding tables, check whether the grants in
  `apply_schema.py` still express the intended permissions.

## About secrets

- Secrets (`NEON_DATABASE_URL`, `COURSEGEN_DATABASE_URL`,
  `OPENAI_API_KEY`, `LANGFUSE_*`, `JWT_SECRET_KEY`, etc.) are read from
  the local `.env`, which is git-ignored. Never hardcode them in the
  HTML pages, scripts or SQL, and never print their values.

## About Python code

Always follow these guidelines when writing or editing Python code in
this project:

- Always use `uv` as the package manager whenever a package needs to be
  installed.
- Write all docstrings in English.
- Docstrings must be complete: describe the input parameters
  (`Parameters`) and the return value (`Returns`).
- When a function or method is complex, include a usage example in the
  docstring (`Example` section).
- Respect the per-line character limit in docstrings according to
  PEP 8 / PEP 257 (79 characters).
- Variables, functions, classes and methods must have descriptive,
  meaningful names written in English.
- Use type hints on function and method parameters and return values.
- Do not use type hints on simple variable assignments inside the body
  of the code.
- Do not add comments in the code — keep only the docstrings.
- Whenever a function or method has 2 or more parameters, break the
  signature across multiple lines, one parameter per line, for example:

```python
def func1(
    param_1: type_1,
    param_2: type_2,
    ...
    param_n: type_n,
) -> type_of_return:
```

- Always check whether the existing documentation (README, docstrings,
  the header of `db/schema.sql`) is still consistent with the change;
  if it needs an update, update it right away.
