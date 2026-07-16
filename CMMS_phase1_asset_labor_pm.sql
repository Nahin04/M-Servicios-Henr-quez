-- CMMS/EAM - Phase 1 DDL (Plant/Asset Backbone + Labor/Crafts + OT core + Checklists + PM schedules)
-- Stack: PostgreSQL + TimescaleDB + RabbitMQ + MQTT (no requiere Timescale en esta fase)

-- Extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Enums (reusable). Si ya existen en tu CMMS_schema.sql, puedes omitir.
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

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'craft_type') THEN
    CREATE TYPE craft_type AS ENUM ('MECHANICAL','ELECTRICAL','INSTRUMENT','PREDICTIVE','WELDING','OTHER');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'shift_status') THEN
    CREATE TYPE shift_status AS ENUM ('ACTIVE','INACTIVE');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'pm_trigger_type') THEN
    CREATE TYPE pm_trigger_type AS ENUM ('CALENDAR_BASED','METER_BASED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'checklist_item_type') THEN
    CREATE TYPE checklist_item_type AS ENUM ('TEXT','BOOLEAN','NUMERIC','CHOICE');
  END IF;
END$$;

-- =========================
-- 1) Asset Registry & Location Tree
-- =========================
-- Estructura organizacional
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

-- FunctionalLocation (ubicación funcional dentro del árbol)
CREATE TABLE IF NOT EXISTS functional_location (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id        uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  area_id         uuid NULL REFERENCES area(id) ON DELETE SET NULL,
  line_id         uuid NULL REFERENCES line(id) ON DELETE SET NULL,
  code            text NOT NULL,
  name            text NOT NULL,
  parent_id       uuid NULL REFERENCES functional_location(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, code)
);

-- Asset / Equipment (activos padre/hijo). Modela el historial independiente del activo.
CREATE TABLE IF NOT EXISTS asset_equipment (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id            uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,

  -- ubicación funcional (ej: Posición A Línea 1)
  functional_location_id uuid NULL REFERENCES functional_location(id) ON DELETE SET NULL,

  -- relaciones padre/hijo
  parent_asset_id    uuid NULL REFERENCES asset_equipment(id) ON DELETE SET NULL,

  type                text NOT NULL, -- EQUIPMENT/VEHICLE/TOOL/SUBASSEMBLY
  code                text NOT NULL,
  name                text NOT NULL,

  description         text NULL,
  criticality_class  smallint NOT NULL DEFAULT 1,

  -- estado de registro
  status              text NOT NULL DEFAULT 'ACTIVE', -- ACTIVE/INACTIVE/OBSOLETE

  created_at          timestamptz NOT NULL DEFAULT now(),

  UNIQUE (plant_id, code)
);

CREATE INDEX IF NOT EXISTS idx_asset_equipment_parent ON asset_equipment(parent_asset_id);
CREATE INDEX IF NOT EXISTS idx_asset_equipment_functional_location ON asset_equipment(functional_location_id);

-- TechnicalSpecification (ficha técnica)
CREATE TABLE IF NOT EXISTS technical_specification (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  asset_id      uuid NOT NULL REFERENCES asset_equipment(id) ON DELETE CASCADE,
  spec_key      text NOT NULL,
  spec_value    text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (asset_id, spec_key)
);

-- Componentes / sub-ensamblajes como relación explícita (opcional; también se puede usar parent_asset_id)
CREATE TABLE IF NOT EXISTS asset_component (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id           uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  parent_asset_id    uuid NOT NULL REFERENCES asset_equipment(id) ON DELETE CASCADE,
  child_asset_id     uuid NOT NULL REFERENCES asset_equipment(id) ON DELETE RESTRICT,
  position_code      text NULL,
  qty_per_parent     numeric NOT NULL DEFAULT 1,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (parent_asset_id, child_asset_id, position_code)
);

-- =========================
-- 2) Labor & Crafts (gestión de talento y tarifas)
-- =========================
CREATE TABLE IF NOT EXISTS craft (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id    uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  code        text NOT NULL,
  name        text NOT NULL,
  craft_type  craft_type NOT NULL DEFAULT 'OTHER',
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, code)
);

CREATE TABLE IF NOT EXISTS technician (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id       uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  craft_id       uuid NOT NULL REFERENCES craft(id) ON DELETE RESTRICT,
  employee_code  text NOT NULL,
  full_name      text NOT NULL,
  status         text NOT NULL DEFAULT 'ACTIVE',
  hourly_rate    numeric NOT NULL DEFAULT 0,
  overtime_rate  numeric NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, employee_code)
);

-- Turnos / Calendarios
CREATE TABLE IF NOT EXISTS shift (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  code          text NOT NULL,
  name          text NOT NULL,
  status        shift_status NOT NULL DEFAULT 'ACTIVE',
  created_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, code)
);

-- Shift schedule por rango temporal
CREATE TABLE IF NOT EXISTS shift_schedule (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id       uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  shift_id       uuid NOT NULL REFERENCES shift(id) ON DELETE CASCADE,
  day_of_week    int NULL CHECK (day_of_week between 0 and 6), -- 0=Sunday...
  start_time     time NOT NULL,
  end_time       time NOT NULL,
  effective_from date NOT NULL,
  effective_to   date NULL,
  created_at     timestamptz NOT NULL DEFAULT now()
);

-- =========================
-- 3) Maintenance Core Inicial (OT y Checklists)
-- =========================
-- (OT base se asume o se crea aquí; si ya existe en CMMS_schema.sql, evita duplicar)
CREATE TABLE IF NOT EXISTS work_order (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id          uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  equipment_asset_id uuid NULL REFERENCES asset_equipment(id) ON DELETE SET NULL,
  work_order_type   work_order_type NOT NULL,
  status            work_order_status NOT NULL DEFAULT 'DRAFT',

  title             text NOT NULL,
  description       text NULL,

  failure_event_id uuid NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  released_at       timestamptz NULL,
  started_at        timestamptz NULL,
  blocked_at        timestamptz NULL,
  done_at           timestamptz NULL,

  correlation_id    uuid NULL,

  UNIQUE (id)
);

-- OT assignment a craft/technician
CREATE TABLE IF NOT EXISTS work_order_assignment (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id  uuid NOT NULL REFERENCES work_order(id) ON DELETE CASCADE,
  technician_id  uuid NULL REFERENCES technician(id) ON DELETE SET NULL,
  craft_id       uuid NULL REFERENCES craft(id) ON DELETE SET NULL,

  role_code      text NULL, -- PRIMARY/SECONDARY/SUPPORT
  planned_hours  numeric NULL,
  actual_hours   numeric NULL,

  created_at     timestamptz NOT NULL DEFAULT now()
);

-- Work Order Checklists (procedimientos de ejecución)
CREATE TABLE IF NOT EXISTS checklist_template (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id      uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  work_order_type work_order_type NOT NULL,
  name          text NOT NULL,
  description   text NULL,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS checklist_item_template (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  checklist_template_id    uuid NOT NULL REFERENCES checklist_template(id) ON DELETE CASCADE,
  sequence_no              int NOT NULL,
  item_type                checklist_item_type NOT NULL DEFAULT 'TEXT',

  question_text            text NOT NULL,
  choice_options_json     jsonb NULL, -- si item_type=CHOICE
  created_at              timestamptz NOT NULL DEFAULT now(),

  UNIQUE (checklist_template_id, sequence_no)
);

CREATE TABLE IF NOT EXISTS work_order_checklist (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_id     uuid NOT NULL REFERENCES work_order(id) ON DELETE CASCADE,
  checklist_template_id uuid NOT NULL REFERENCES checklist_template(id) ON DELETE RESTRICT,
  status             text NOT NULL DEFAULT 'IN_PROGRESS', -- IN_PROGRESS/COMPLETED/APPROVED
  created_at         timestamptz NOT NULL DEFAULT now(),
  completed_at       timestamptz NULL
);

CREATE TABLE IF NOT EXISTS work_order_checklist_item_result (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_order_checklist_id uuid NOT NULL REFERENCES work_order_checklist(id) ON DELETE CASCADE,
  checklist_item_template_id uuid NOT NULL REFERENCES checklist_item_template(id) ON DELETE RESTRICT,

  answer_text             text NULL,
  answer_boolean          boolean NULL,
  answer_numeric          numeric NULL,
  answer_choice           text NULL,

  evidence_ref            text NULL, -- URL/path/asset ref
  status                  text NOT NULL DEFAULT 'PENDING',
  updated_at              timestamptz NOT NULL DEFAULT now(),
  UNIQUE (work_order_checklist_id, checklist_item_template_id)
);

-- =========================
-- 4) PM Triggers & Frequencies (Preventivo: calendar/meter)
-- =========================
CREATE TABLE IF NOT EXISTS maintenance_plan (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plant_id           uuid NOT NULL REFERENCES plant(id) ON DELETE RESTRICT,
  asset_id           uuid NOT NULL REFERENCES asset_equipment(id) ON DELETE CASCADE,
  name               text NOT NULL,
  work_order_type   work_order_type NOT NULL DEFAULT 'PREVENTIVE',
  enabled            boolean NOT NULL DEFAULT true,
  created_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (plant_id, asset_id, name)
);

-- Disparadores PM: por tiempo o por uso/medidor (SCADA meter-based)
CREATE TABLE IF NOT EXISTS pm_trigger (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  maintenance_plan_id uuid NOT NULL REFERENCES maintenance_plan(id) ON DELETE CASCADE,
  trigger_type      pm_trigger_type NOT NULL,

  -- calendar-based
  interval_days     int NULL CHECK (interval_days IS NULL OR interval_days > 0),

  -- meter-based
  meter_key         text NULL, -- tagKey o nombre del medidor (ej: RUNTIME_HOURS, KM)
  interval_units    numeric NULL CHECK (interval_units IS NULL OR interval_units > 0),

  -- ejecución
  next_due_at       timestamptz NULL,
  next_due_meter_value numeric NULL,

  enabled           boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),

  UNIQUE (maintenance_plan_id, trigger_type, meter_key, interval_days)
);

-- PM schedule: reglas para generar OT
CREATE TABLE IF NOT EXISTS pm_schedule (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  maintenance_plan_id uuid NOT NULL REFERENCES maintenance_plan(id) ON DELETE CASCADE,
  trigger_id           uuid NULL REFERENCES pm_trigger(id) ON DELETE SET NULL,
  title                text NULL,
  created_at           timestamptz NOT NULL DEFAULT now()
);

-- OT generadas desde PM (relación)
CREATE TABLE IF NOT EXISTS pm_generated_work_order (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pm_schedule_id       uuid NOT NULL REFERENCES pm_schedule(id) ON DELETE CASCADE,
  work_order_id        uuid NOT NULL REFERENCES work_order(id) ON DELETE CASCADE,
  generated_at         timestamptz NOT NULL DEFAULT now(),
  due_at                timestamptz NULL,
  meter_value_at_gen    numeric NULL,

  UNIQUE (pm_schedule_id, work_order_id)
);

-- =========================
-- End of Phase 1
-- =========================
-- Recomendación: ejecútalo primero. Luego integra inventario/costos/fallas/quality/kpi.

