-- =====================================================================
-- CourseGen Studio — esquema do banco (Neon / PostgreSQL 16+)
--
-- Tudo vive no schema "coursegen", isolado dos demais projetos que
-- compartilham o banco (public, pgl_auth, pgl_proxy, agent_conversations).
-- O script é idempotente: pode ser executado mais de uma vez.
--
-- Mapa tela → tabelas
--   Login / recuperação ....... users, user_sessions, password_reset_tokens
--   Perfis (RBAC) ............. organizations, organization_members
--   Meus cursos ............... courses, course_versions
--   Novo curso · Briefing ..... course_briefings, competencies, briefing_competencies,
--                               briefing_sources
--   Estrutura ................. modules, lessons, learning_objectives, bloom_levels
--   Plano de aula ............. lesson_sections, lesson_sources, ai_generations
--   Avaliação e alinhamento ... activities, activity_objectives, questions,
--                               question_options, question_objectives,
--                               version_questions, rubrics, rubric_*
--   Biblioteca ................ questions, rubrics (escopo da organização)
--   Modelos ................... pedagogical_models
--   Fontes (RAG) .............. sources, source_documents, source_chunks
--   Versões / Revisão ......... course_versions, version_reviews, comments
--   Exportações ............... exports
--   Integrações / API REST .... api_tokens
--   Trilha de auditoria ....... audit_log
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS citext;

CREATE SCHEMA IF NOT EXISTS coursegen;
SET search_path = coursegen, public;

-- ---------------------------------------------------------------------
-- Utilitário: updated_at automático
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION coursegen.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- =====================================================================
-- 1. Tenants, usuários e acesso
-- =====================================================================

-- Cada organização é um tenant isolado (landing: "Isolamento por tenant").
CREATE TABLE IF NOT EXISTS organizations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  slug          text NOT NULL UNIQUE,
  email_domain  citext,                       -- ex.: instituicao.edu.br
  deployment    text NOT NULL DEFAULT 'saas'
                CHECK (deployment IN ('saas', 'private_cloud')),
  settings      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS users (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email           citext NOT NULL UNIQUE,     -- "E-mail institucional"
  password_hash   text,                       -- nulo quando o login é só via SSO/IdP
  full_name       text NOT NULL,              -- "Camila Torres"
  job_title       text,                       -- "Instructional designer"
  is_active       boolean NOT NULL DEFAULT true,
  last_login_at   timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Perfil do usuário em cada organização (RBAC).
CREATE TABLE IF NOT EXISTS organization_members (
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  user_id         uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role            text NOT NULL
                  CHECK (role IN ('author', 'reviewer', 'curator', 'admin')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, user_id, role)
);

-- "Manter conectado neste dispositivo" → sessão longa (refresh token).
CREATE TABLE IF NOT EXISTS user_sessions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id            uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_hash text NOT NULL UNIQUE,
  keep_signed_in     boolean NOT NULL DEFAULT false,
  user_agent         text,
  ip_address         inet,
  created_at         timestamptz NOT NULL DEFAULT now(),
  expires_at         timestamptz NOT NULL,
  revoked_at         timestamptz
);
CREATE INDEX IF NOT EXISTS user_sessions_user_idx ON user_sessions (user_id);

-- "Esqueci minha senha"
CREATE TABLE IF NOT EXISTS password_reset_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  text NOT NULL UNIQUE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz
);
CREATE INDEX IF NOT EXISTS password_reset_tokens_user_idx ON password_reset_tokens (user_id);

-- API REST: "Autenticação por token Bearer"
CREATE TABLE IF NOT EXISTS api_tokens (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  name            text NOT NULL,
  token_prefix    text NOT NULL,               -- primeiros caracteres, para exibição
  token_hash      text NOT NULL UNIQUE,
  scopes          text[] NOT NULL DEFAULT '{}',
  last_used_at    timestamptz,
  expires_at      timestamptz,
  revoked_at      timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);

-- =====================================================================
-- 2. Catálogos pedagógicos
-- =====================================================================

-- Taxonomia de Bloom revisada (dados de referência, globais).
CREATE TABLE IF NOT EXISTS bloom_levels (
  id          smallint PRIMARY KEY,           -- 1..6, ordem cognitiva
  code        text NOT NULL UNIQUE,           -- remember, understand, ...
  name_pt     text NOT NULL,                  -- Lembrar, Entender, ...
  sample_verbs text[] NOT NULL DEFAULT '{}'   -- "Listar, identificar"
);

-- Modelos pedagógicos: versionados e compartilhados entre autores.
-- organization_id nulo = modelo padrão da plataforma.
CREATE TABLE IF NOT EXISTS pedagogical_models (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid REFERENCES organizations(id) ON DELETE CASCADE,
  family_key      text NOT NULL,              -- agrupa as versões de um mesmo modelo
  version         text NOT NULL,              -- "v1.0"
  name            text NOT NULL,              -- "Aprendizagem baseada em projetos"
  description     text,
  typical_use     text,                       -- "capacitação aplicada"
  structure       jsonb NOT NULL DEFAULT '{}'::jsonb,   -- estrutura-base (seções da aula etc.)
  constraints     jsonb NOT NULL DEFAULT '{}'::jsonb,   -- restrições aplicadas à geração
  is_active       boolean NOT NULL DEFAULT true,
  created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS pedagogical_models_version_uq
  ON pedagogical_models (COALESCE(organization_id, '00000000-0000-0000-0000-000000000000'::uuid), family_key, version);

-- Competências-alvo ("Interpretar dados", "Comunicar insights").
CREATE TABLE IF NOT EXISTS competencies (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name            text NOT NULL,
  description     text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

-- =====================================================================
-- 3. Fontes institucionais (RAG)
-- =====================================================================

CREATE TABLE IF NOT EXISTS sources (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name             text NOT NULL,             -- "Manual de BI"
  category         text NOT NULL
                   CHECK (category IN ('teaching_material', 'policy', 'question_bank', 'existing_course', 'other')),
  owner_user_id    uuid REFERENCES users(id) ON DELETE SET NULL,
  owner_label      text,                      -- responsável sem conta ("Coordenação")
  status           text NOT NULL DEFAULT 'up_to_date'
                   CHECK (status IN ('up_to_date', 'review_pending', 'archived')),
  last_reviewed_at timestamptz,
  review_interval  interval DEFAULT interval '90 days',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, name)
);

-- Arquivos enviados para cada fonte.
CREATE TABLE IF NOT EXISTS source_documents (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_id     uuid NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  file_name     text NOT NULL,
  mime_type     text,
  storage_uri   text NOT NULL,                -- caminho no object storage do tenant
  byte_size     bigint,
  checksum      text,
  ingest_status text NOT NULL DEFAULT 'pending'
                CHECK (ingest_status IN ('pending', 'processing', 'indexed', 'failed')),
  ingest_error  text,
  uploaded_by   uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS source_documents_source_idx ON source_documents (source_id);

-- Trechos indexados. organization_id é desnormalizado para filtrar por tenant
-- em toda consulta vetorial ("sem consulta cruzada entre tenants").
CREATE TABLE IF NOT EXISTS source_chunks (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  document_id     uuid NOT NULL REFERENCES source_documents(id) ON DELETE CASCADE,
  chunk_index     integer NOT NULL,
  content         text NOT NULL,
  token_count     integer,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,   -- página, seção etc.
  embedding       vector(1536),                         -- text-embedding-3-small
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (document_id, chunk_index)
);
CREATE INDEX IF NOT EXISTS source_chunks_org_idx ON source_chunks (organization_id);
CREATE INDEX IF NOT EXISTS source_chunks_embedding_idx
  ON source_chunks USING hnsw (embedding vector_cosine_ops);

-- =====================================================================
-- 4. Cursos e versões
-- =====================================================================

CREATE TABLE IF NOT EXISTS courses (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id     uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  public_code         text,                   -- "cr_41" (usado na URL)
  title               text NOT NULL,
  owner_id            uuid REFERENCES users(id) ON DELETE SET NULL,
  current_version_id  uuid,                   -- FK adicionada após course_versions
  approved_version_id uuid,                   -- última versão aprovada (exportável)
  archived_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organization_id, public_code)
);
CREATE INDEX IF NOT EXISTS courses_org_idx ON courses (organization_id);

-- "Toda geração ou edição cria uma nova versão."
-- O conteúdo (módulos, aulas, objetivos...) pertence a uma versão;
-- criar uma versão nova = copiar a árvore da versão anterior.
CREATE TABLE IF NOT EXISTS course_versions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_id          uuid NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
  version_label      text NOT NULL,           -- "v2.0"
  major              integer NOT NULL,
  minor              integer NOT NULL,
  parent_version_id  uuid REFERENCES course_versions(id) ON DELETE SET NULL,
  status             text NOT NULL DEFAULT 'ai_generated'
                     CHECK (status IN ('ai_generated', 'edited', 'in_review', 'approved', 'rejected')),
  flow_stage         text NOT NULL DEFAULT 'briefing'
                     CHECK (flow_stage IN ('briefing', 'structure', 'content', 'assessment', 'review')),
  change_summary     text,                    -- "Rascunho inicial"
  created_by         uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  submitted_at       timestamptz,
  approved_by        uuid REFERENCES users(id) ON DELETE SET NULL,
  approved_at        timestamptz,
  UNIQUE (course_id, major, minor),
  CHECK (status <> 'approved' OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS course_versions_course_idx ON course_versions (course_id, created_at DESC);

DO $$ BEGIN
  ALTER TABLE courses ADD CONSTRAINT courses_current_version_fk
    FOREIGN KEY (current_version_id) REFERENCES course_versions(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  ALTER TABLE courses ADD CONSTRAINT courses_approved_version_fk
    FOREIGN KEY (approved_version_id) REFERENCES course_versions(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Etapa 1 · Briefing (um por versão)
CREATE TABLE IF NOT EXISTS course_briefings (
  course_version_id    uuid PRIMARY KEY REFERENCES course_versions(id) ON DELETE CASCADE,
  target_audience      text,                  -- "Analistas júnior, corporativo"
  workload_hours       numeric(6,1),          -- 40
  duration_weeks       integer,               -- 8
  educational_goals    text,                  -- objetivos educacionais (texto livre)
  pedagogical_model_id uuid REFERENCES pedagogical_models(id) ON DELETE SET NULL,
  taxonomy             text NOT NULL DEFAULT 'bloom_revised',
  lesson_format        text,                  -- "Teoria + prática, 50/50"
  assessment_strategy  text,                  -- "Quiz + projeto final"
  extra                jsonb NOT NULL DEFAULT '{}'::jsonb,
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS briefing_competencies (
  course_version_id uuid NOT NULL REFERENCES course_briefings(course_version_id) ON DELETE CASCADE,
  competency_id     uuid NOT NULL REFERENCES competencies(id) ON DELETE CASCADE,
  PRIMARY KEY (course_version_id, competency_id)
);

CREATE TABLE IF NOT EXISTS briefing_sources (
  course_version_id uuid NOT NULL REFERENCES course_briefings(course_version_id) ON DELETE CASCADE,
  source_id         uuid NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  PRIMARY KEY (course_version_id, source_id)
);

-- =====================================================================
-- 5. Estrutura: módulos, aulas, objetivos
-- =====================================================================

CREATE TABLE IF NOT EXISTS modules (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  position          integer NOT NULL,         -- M1, M2...
  title             text NOT NULL,
  description       text,
  workload_hours    numeric(6,1),
  UNIQUE (course_version_id, position)
);

CREATE TABLE IF NOT EXISTS lessons (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  module_id        uuid NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
  position         integer NOT NULL,          -- Aula 2.1 → módulo 2, posição 1
  title            text NOT NULL,
  duration_minutes integer,                   -- 90
  status           text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft', 'edited', 'reviewed')),
  UNIQUE (module_id, position)
);

-- Objetivos de aprendizagem, cada um com um nível de Bloom.
-- Ficam na aula ou, quando gerais, no módulo/curso.
CREATE TABLE IF NOT EXISTS learning_objectives (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  module_id         uuid REFERENCES modules(id) ON DELETE CASCADE,
  lesson_id         uuid REFERENCES lessons(id) ON DELETE CASCADE,
  position          integer NOT NULL DEFAULT 0,
  statement         text NOT NULL,            -- "Calcular média, mediana e moda..."
  bloom_level_id    smallint NOT NULL REFERENCES bloom_levels(id),
  competency_id     uuid REFERENCES competencies(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS learning_objectives_version_idx ON learning_objectives (course_version_id);
CREATE INDEX IF NOT EXISTS learning_objectives_lesson_idx ON learning_objectives (lesson_id);

-- =====================================================================
-- 6. Conteúdo: plano de aula
-- =====================================================================

CREATE TABLE IF NOT EXISTS lesson_sections (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lesson_id        uuid NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
  position         integer NOT NULL,
  kind             text NOT NULL
                   CHECK (kind IN ('opening', 'development', 'practice', 'closing', 'other')),
  title            text NOT NULL,             -- "Abertura"
  duration_minutes integer,                   -- 10
  body             text NOT NULL DEFAULT '',  -- markdown
  materials        jsonb NOT NULL DEFAULT '[]'::jsonb,
  status           text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft', 'edited', 'reviewed')),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (lesson_id, position)
);

-- "Fontes usadas" na aula
CREATE TABLE IF NOT EXISTS lesson_sources (
  lesson_id uuid NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
  source_id uuid NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  PRIMARY KEY (lesson_id, source_id)
);

-- =====================================================================
-- 7. Avaliação e alinhamento
-- =====================================================================

-- Atividades ("Prática 2.1", "Leitura 2.2")
CREATE TABLE IF NOT EXISTS activities (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  lesson_id         uuid REFERENCES lessons(id) ON DELETE CASCADE,
  code              text NOT NULL,            -- "Prática 2.1"
  kind              text NOT NULL DEFAULT 'practice'
                    CHECK (kind IN ('practice', 'reading', 'project', 'discussion', 'other')),
  title             text,
  instructions      text
);

CREATE TABLE IF NOT EXISTS activity_objectives (
  activity_id  uuid NOT NULL REFERENCES activities(id) ON DELETE CASCADE,
  objective_id uuid NOT NULL REFERENCES learning_objectives(id) ON DELETE CASCADE,
  PRIMARY KEY (activity_id, objective_id)
);

-- Banco de questões (Biblioteca) — escopo da organização, reutilizável.
CREATE TABLE IF NOT EXISTS questions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  code            text,                       -- "Q1"
  stem            text NOT NULL,              -- enunciado
  kind            text NOT NULL
                  CHECK (kind IN ('multiple_choice', 'essay', 'project')),
  bloom_level_id  smallint NOT NULL REFERENCES bloom_levels(id),
  answer_key      text,                       -- gabarito / resposta esperada
  status          text NOT NULL DEFAULT 'generated'
                  CHECK (status IN ('generated', 'reviewed', 'archived')),
  origin          text NOT NULL DEFAULT 'ai'
                  CHECK (origin IN ('ai', 'manual', 'imported')),
  rubric_id       uuid,                       -- FK adicionada após rubrics
  created_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  reviewed_by     uuid REFERENCES users(id) ON DELETE SET NULL,
  reviewed_at     timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS questions_org_idx ON questions (organization_id, kind, status);

CREATE TABLE IF NOT EXISTS question_options (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  question_id uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  position    integer NOT NULL,
  text        text NOT NULL,
  is_correct  boolean NOT NULL DEFAULT false,
  feedback    text,
  UNIQUE (question_id, position)
);

-- Questões usadas numa versão de curso (avaliações do módulo/aula).
CREATE TABLE IF NOT EXISTS version_questions (
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  question_id       uuid NOT NULL REFERENCES questions(id) ON DELETE RESTRICT,
  module_id         uuid REFERENCES modules(id) ON DELETE CASCADE,
  lesson_id         uuid REFERENCES lessons(id) ON DELETE CASCADE,
  label             text,                     -- rótulo local ("Q1")
  position          integer NOT NULL DEFAULT 0,
  PRIMARY KEY (course_version_id, question_id)
);

-- Matriz objetivo × questão
CREATE TABLE IF NOT EXISTS question_objectives (
  question_id  uuid NOT NULL REFERENCES questions(id) ON DELETE CASCADE,
  objective_id uuid NOT NULL REFERENCES learning_objectives(id) ON DELETE CASCADE,
  PRIMARY KEY (question_id, objective_id)
);

-- Rubricas ("Projeto final · 4 critérios · 4 níveis")
CREATE TABLE IF NOT EXISTS rubrics (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  course_version_id uuid REFERENCES course_versions(id) ON DELETE SET NULL,  -- nulo = só biblioteca
  title             text NOT NULL,
  description       text,
  status            text NOT NULL DEFAULT 'generated'
                    CHECK (status IN ('generated', 'reviewed', 'archived')),
  created_by        uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS rubric_levels (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rubric_id uuid NOT NULL REFERENCES rubrics(id) ON DELETE CASCADE,
  position  integer NOT NULL,
  name      text NOT NULL,                    -- "Insuficiente", "Proficiente"...
  points    numeric(6,2),
  UNIQUE (rubric_id, position)
);

CREATE TABLE IF NOT EXISTS rubric_criteria (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rubric_id uuid NOT NULL REFERENCES rubrics(id) ON DELETE CASCADE,
  position  integer NOT NULL,
  name      text NOT NULL,
  weight    numeric(5,2) NOT NULL DEFAULT 1,
  UNIQUE (rubric_id, position)
);

-- Descritor de cada célula critério × nível
CREATE TABLE IF NOT EXISTS rubric_descriptors (
  criterion_id uuid NOT NULL REFERENCES rubric_criteria(id) ON DELETE CASCADE,
  level_id     uuid NOT NULL REFERENCES rubric_levels(id) ON DELETE CASCADE,
  description  text NOT NULL,
  PRIMARY KEY (criterion_id, level_id)
);

-- "Alinhada a: objetivos dos módulos 2 e 3"
CREATE TABLE IF NOT EXISTS rubric_objectives (
  rubric_id    uuid NOT NULL REFERENCES rubrics(id) ON DELETE CASCADE,
  objective_id uuid NOT NULL REFERENCES learning_objectives(id) ON DELETE CASCADE,
  PRIMARY KEY (rubric_id, objective_id)
);

DO $$ BEGIN
  ALTER TABLE questions ADD CONSTRAINT questions_rubric_fk
    FOREIGN KEY (rubric_id) REFERENCES rubrics(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Cobertura por objetivo (tela "Avaliação e alinhamento" e coluna "Cobertura").
CREATE OR REPLACE VIEW objective_coverage AS
SELECT
  o.id                AS objective_id,
  o.course_version_id,
  o.module_id,
  o.lesson_id,
  o.statement,
  o.bloom_level_id,
  count(DISTINCT ao.activity_id) AS activity_count,
  count(DISTINCT qo.question_id) AS question_count,
  CASE
    WHEN count(DISTINCT ao.activity_id) > 0 AND count(DISTINCT qo.question_id) > 0 THEN 'covered'
    WHEN count(DISTINCT qo.question_id) = 0 THEN 'no_question'
    ELSE 'partial'
  END AS coverage
FROM learning_objectives o
LEFT JOIN activity_objectives ao ON ao.objective_id = o.id
LEFT JOIN question_objectives qo ON qo.objective_id = o.id
GROUP BY o.id;

-- =====================================================================
-- 8. Revisão, comentários e aprovação
-- =====================================================================

CREATE TABLE IF NOT EXISTS version_reviews (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  reviewer_id       uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  decision          text NOT NULL
                    CHECK (decision IN ('approved', 'changes_requested', 'rejected')),
  notes             text,
  decided_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS version_reviews_version_idx ON version_reviews (course_version_id);

-- Comentários ancorados em qualquer elemento da versão.
CREATE TABLE IF NOT EXISTS comments (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  parent_id         uuid REFERENCES comments(id) ON DELETE CASCADE,
  target_type       text NOT NULL
                    CHECK (target_type IN ('course', 'module', 'lesson', 'lesson_section',
                                           'objective', 'activity', 'question', 'rubric')),
  target_id         uuid,
  author_id         uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body              text NOT NULL,
  resolved_at       timestamptz,
  resolved_by       uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS comments_version_idx ON comments (course_version_id);

-- =====================================================================
-- 9. Geração por IA (etapas e botões do Assistente)
-- =====================================================================

CREATE TABLE IF NOT EXISTS ai_generations (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id   uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  course_version_id uuid REFERENCES course_versions(id) ON DELETE SET NULL,
  requested_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  action            text NOT NULL
                    CHECK (action IN ('generate_syllabus', 'generate_lesson_plan', 'generate_materials',
                                      'generate_questions', 'generate_missing_questions', 'generate_rubric',
                                      'rewrite', 'simplify', 'add_example', 'generate_slides', 'create_quiz',
                                      'coherence_check')),
  target_type       text,                     -- lesson_section, question...
  target_id         uuid,
  status            text NOT NULL DEFAULT 'queued'
                    CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  model             text,
  input             jsonb NOT NULL DEFAULT '{}'::jsonb,
  output            jsonb,
  retrieved_chunk_ids uuid[] NOT NULL DEFAULT '{}',   -- fontes usadas (auditoria do RAG)
  prompt_tokens     integer,
  completion_tokens integer,
  trace_id          text,                     -- id do trace no Langfuse
  error             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz
);
CREATE INDEX IF NOT EXISTS ai_generations_version_idx ON ai_generations (course_version_id, created_at DESC);

-- =====================================================================
-- 10. Exportações (só de versões aprovadas)
-- =====================================================================

CREATE TABLE IF NOT EXISTS exports (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  course_version_id uuid NOT NULL REFERENCES course_versions(id) ON DELETE CASCADE,
  format            text NOT NULL CHECK (format IN ('pdf', 'pptx', 'html', 'scorm')),
  status            text NOT NULL DEFAULT 'queued'
                    CHECK (status IN ('queued', 'running', 'succeeded', 'failed')),
  storage_uri       text,
  byte_size         bigint,
  error             text,
  requested_by      uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz
);
CREATE INDEX IF NOT EXISTS exports_version_idx ON exports (course_version_id, created_at DESC);

-- Garante a regra "Apenas versões aprovadas podem ser exportadas".
CREATE OR REPLACE FUNCTION coursegen.exports_require_approved() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT status FROM coursegen.course_versions WHERE id = NEW.course_version_id) <> 'approved' THEN
    RAISE EXCEPTION 'Só versões aprovadas podem ser exportadas (versão %)', NEW.course_version_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS exports_require_approved ON exports;
CREATE TRIGGER exports_require_approved BEFORE INSERT ON exports
  FOR EACH ROW EXECUTE FUNCTION coursegen.exports_require_approved();

-- =====================================================================
-- 11. Trilha de auditoria
-- =====================================================================

CREATE TABLE IF NOT EXISTS audit_log (
  id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  organization_id uuid REFERENCES organizations(id) ON DELETE SET NULL,
  actor_user_id   uuid REFERENCES users(id) ON DELETE SET NULL,
  actor_api_token uuid REFERENCES api_tokens(id) ON DELETE SET NULL,
  action          text NOT NULL,              -- "version.approve", "export.create", "login"...
  entity_type     text,
  entity_id       uuid,
  details         jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip_address      inet,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_org_time_idx ON audit_log (organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_log_entity_idx ON audit_log (entity_type, entity_id);

-- =====================================================================
-- Triggers de updated_at
-- =====================================================================
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['organizations', 'users', 'pedagogical_models', 'sources', 'courses',
                           'course_briefings', 'lesson_sections', 'questions', 'rubrics']
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I_touch ON coursegen.%I', t, t);
    EXECUTE format('CREATE TRIGGER %I_touch BEFORE UPDATE ON coursegen.%I
                    FOR EACH ROW EXECUTE FUNCTION coursegen.touch_updated_at()', t, t);
  END LOOP;
END $$;

-- =====================================================================
-- Dados de referência
-- =====================================================================
INSERT INTO bloom_levels (id, code, name_pt, sample_verbs) VALUES
  (1, 'remember',   'Lembrar',  ARRAY['Listar', 'identificar']),
  (2, 'understand', 'Entender', ARRAY['Explicar', 'resumir']),
  (3, 'apply',      'Aplicar',  ARRAY['Calcular', 'usar']),
  (4, 'analyze',    'Analisar', ARRAY['Comparar', 'examinar']),
  (5, 'evaluate',   'Avaliar',  ARRAY['Julgar', 'criticar']),
  (6, 'create',     'Criar',    ARRAY['Projetar', 'propor'])
ON CONFLICT (id) DO UPDATE
  SET code = EXCLUDED.code, name_pt = EXCLUDED.name_pt, sample_verbs = EXCLUDED.sample_verbs;

-- Modelos pedagógicos padrão da plataforma (organization_id nulo)
INSERT INTO pedagogical_models (organization_id, family_key, version, name, description, typical_use)
SELECT NULL, v.family_key, 'v1.0', v.name, v.description, v.typical_use
FROM (VALUES
  ('theory_practice', 'Teoria + prática',                  'Alternância entre exposição e atividade.',        'Cursos técnicos e universitários.'),
  ('project_based',   'Aprendizagem baseada em projetos',  'Projeto central com entregas ao longo do curso.', 'Capacitação aplicada.'),
  ('microlearning',   'Microlearning',                     'Unidades curtas e focadas.',                       'Treinamentos corporativos rápidos.'),
  ('flipped',         'Aula invertida',                    'Estudo prévio e atividade em sala.',               'Cursos com encontros síncronos.')
) AS v(family_key, name, description, typical_use)
WHERE NOT EXISTS (
  SELECT 1 FROM pedagogical_models m
  WHERE m.organization_id IS NULL AND m.family_key = v.family_key AND m.version = 'v1.0'
);
