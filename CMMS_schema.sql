-- CMMS/EAM DDL Físico (PostgreSQL + TimescaleDB)
-- Archivo: CMMS_schema.sql
-- Stack: PostgreSQL + TimescaleDB + RabbitMQ + MQTT

-- =========================
-- Extensions
-- =========================
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- =========================
-- Enums base
-- =========================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'org_status') THEN
    CREATE TYPE org_status AS ENUM ('ACTIVE','INACTIVE');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'work_order_type') THEN
    CREATE TYPE work_order_type AS ENUM ('CORRECTIVE','PREVENTIVE','PREDICTIVE');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'work_order_status') THEN
    CREATE TYPE work_order_status AS ENUM ('DRAFT','RELEASED','IN_PROGRESS','BLOCKED','DONE','CANCELLED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'failure_status') THEN
    CREATE TYPE failure_status AS ENUM ('OPEN','INVESTIGATING','RESOLVED','ESCALATED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'downtime_type') THEN
    CREATE TYPE downtime_type AS ENUM ('PLANNED','UNPLANNED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cost_scope') THEN
    CREATE TYPE cost_scope AS ENUM ('DIRECT','INDIRECT');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'cost_source_type') THEN
    CREATE TYPE cost_source_type AS ENUM ('LABOR','INVENTORY','EXTERNAL_SERVICE','DOWNTIME_LOSS');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'approval_decision') THEN
    CREATE TYPE approval_decision AS ENUM ('APPROVED','DECLINED','NEEDS_INFO','SKIPPED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'quality_result') THEN
    CREATE TYPE quality_result AS ENUM ('PASS','FAIL');
  END IF;
END$$;

-- =========================
-- Organization / Plant hierarchy
-- =========================
CREATE TABLE IF NOT EXISTS organization (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL,
  status          org_status NOT NULL DEFAULT 'ACTIVE',
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS plant (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid NOT NULL REFERENCES organization(id) ON DELETE RESTRICT,
  code            text NOT NULL,
  name            text NOT NULL,
  status          org_status NOT NULL DEFAULT 'ACTIVE',
  UNIQUE (organization_id, code)
);

CREATE TABLE IF NOT EXISTS area (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id  uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  code      text NOT NULL,
  name      text NOT NULL,
  UNIQUE (plant_id, code)
);

CREATE TABLE IF NOT EXISTS line (
  id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  area_id   uuid NOT NULL REFERENCES area(id) ON DELETE RESTRICT,
  code      text NOT NULL,
  name      text NOT NULL,
  UNIQUE (area_id, code)
);

CREATE TABLE IF NOT EXISTS equipment (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  line_id         uuid NOT NULL REFERENCES line(id) ON DELETE RESTRICT,
  code            text NOT NULL,
  name            text NOT NULL,
  criticality_class smallint NOT NULL DEFAULT 1,
  UNIQUE (line_id, code)
);

-- =========================
-- Work Orders
-- =========================
CREATE TABLE IF NOT EXISTS work_order (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id          uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_id     uuid NULL REFERENCES equipment(id) ON DELETE RESTRICT,

  work_order_type   work_order_type NOT NULL,
  status            work_order_status NOT NULL DEFAULT 'DRAFT',

  title             text NOT NULL,
  failure_event_id uuid NULL,
  created_by        uuid NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),

  scheduled_window_id uuid NULL,
  released_at       timestamptz NULL,
  done_at           timestamptz NULL,

  correlation_id    uuid NULL,
  UNIQUE (id)
);

CREATE INDEX IF NOT EXISTS idx_work_order_equipment ON work_order(equipment_id);
CREATE INDEX IF NOT EXISTS idx_work_order_type_status ON work_order(work_order_type, status);

-- =========================
-- Maintenance Windows
-- =========================
CREATE TABLE IF NOT EXISTS maintenance_window (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id         uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_id     uuid NULL REFERENCES equipment(id) ON DELETE RESTRICT,

  start_at         timestamptz NOT NULL,
  end_at           timestamptz NOT NULL,
  capacity_impact_estimate numeric NULL,

  status           text NOT NULL DEFAULT 'REQUESTED',
  requested_by     uuid NULL,
  approved_by      uuid NULL,
  approved_at      timestamptz NULL,

  correlation_id   uuid NULL,
  CHECK (end_at > start_at)
);

CREATE INDEX IF NOT EXISTS idx_maintenance_window_time ON maintenance_window(start_at, end_at);

-- =========================
-- Failure Events
-- =========================
CREATE TABLE IF NOT EXISTS failure_event (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id          uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_id     uuid NOT NULL REFERENCES equipment(id) ON DELETE RESTRICT,

  reported_at      timestamptz NOT NULL DEFAULT now(),
  reported_by      uuid NULL,

  severity         smallint NOT NULL DEFAULT 1,
  status           failure_status NOT NULL DEFAULT 'OPEN',

  symptom_text     text NULL,
  shift_code       text NULL,
  area_id          uuid NULL REFERENCES area(id) ON DELETE SET NULL,

  external_source_id text NULL,
  correlation_id   uuid NULL,

  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_failure_event_equipment_status ON failure_event(equipment_id, status);
CREATE INDEX IF NOT EXISTS idx_failure_event_reported_at ON failure_event(reported_at);

-- =========================
-- Downtime Events
-- =========================
CREATE TABLE IF NOT EXISTS downtime_event (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_id uuid NOT NULL REFERENCES equipment(id) ON DELETE RESTRICT,

  failure_event_id uuid NULL REFERENCES failure_event(id) ON DELETE SET NULL,
  work_order_id uuid NULL REFERENCES work_order(id) ON DELETE SET NULL,

  downtime_reason_code text NULL,
  downtime_type downtime_type NOT NULL DEFAULT 'UNPLANNED',

  start_at timestamptz NOT NULL,
  end_at timestamptz NULL,

  duration_minutes numeric GENERATED ALWAYS AS (
    CASE WHEN end_at IS NULL THEN NULL
         ELSE EXTRACT(EPOCH FROM (end_at - start_at))/60
    END
  ) STORED,

  created_at timestamptz NOT NULL DEFAULT now(),
  approved_by uuid NULL,

  CHECK (end_at IS NULL OR end_at > start_at)
);

CREATE INDEX IF NOT EXISTS idx_downtime_equipment_time ON downtime_event(equipment_id, start_at, end_at);
CREATE INDEX IF NOT EXISTS idx_downtime_failure ON downtime_event(failure_event_id);

-- =========================
-- SCADA + TimescaleDB Hypertable
-- =========================
CREATE TABLE IF NOT EXISTS scada_tag (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_id uuid NULL REFERENCES equipment(id) ON DELETE SET NULL,

  tag_key text NOT NULL,
  unit text NULL,

  min_value numeric NULL,
  max_value numeric NULL,

  sampling_mode text NULL,
  created_at timestamptz NOT NULL DEFAULT now(),

  UNIQUE (plant_id, tag_key)
);

CREATE TABLE IF NOT EXISTS predictive_rule (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,

  rule_key text NOT NULL,
  rule_type text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,

  expression_json jsonb NOT NULL,

  severity smallint NOT NULL DEFAULT 1,
  cooldown_minutes int NULL,

  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS predictive_rule_tag (
  rule_id uuid NOT NULL REFERENCES predictive_rule(id) ON DELETE CASCADE,
  tag_id uuid NOT NULL REFERENCES scada_tag(id) ON DELETE CASCADE,
  PRIMARY KEY (rule_id, tag_id)
);

CREATE TABLE IF NOT EXISTS tag_ingestion_event (
  time timestamptz NOT NULL,
  plant_id uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_id uuid NULL REFERENCES equipment(id) ON DELETE SET NULL,
  tag_id uuid NOT NULL REFERENCES scada_tag(id) ON DELETE RESTRICT,

  value numeric NOT NULL,
  quality text NULL,
  source text NULL,
  source_event_id text NULL,
  correlation_id uuid NULL,

  created_at timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (tag_id, time, source_event_id)
);

-- Make it hypertable
SELECT create_hypertable('tag_ingestion_event', 'time', if_not_exists => TRUE, migrate_data => TRUE);
CREATE INDEX IF NOT EXISTS idx_tag_ingestion_event_lookup ON tag_ingestion_event(plant_id, equipment_id, tag_id, time DESC);

-- (El resto de tablas: inventario/OT/costos/calidad/workflow/kpi se agregan en el siguiente commit para mantener este archivo manejable.)

