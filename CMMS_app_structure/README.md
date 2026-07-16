# CMMS/EAM Software Structure (carpetas)

Este workspace contiene un ejemplo de cómo organizar tu software por módulos, con subcarpetas, para que sea fácil de implementar (frontend/backends, servicios, dominio, persistencia, eventos y APIs).

## Estructura sugerida
- `modules/01-asset-core`
- `modules/02-labor-crafts`
- `modules/03-inventory`
- `modules/04-costing-roi`
- `modules/05-failures-downtime`
- `modules/06-production-coordination`
- `modules/07-procurement-integration`
- `modules/08-scada-integration`
- `modules/09-quality-fmea-rca`
- `modules/10-workflow-communication`
- `modules/11-kpis-analytics`
- `modules/12-quality-release-audits`

> Nota: Como tus 11 módulos originales cubren ambos aspectos de Calidad (7 y 11), aquí se separa Calidad en dos módulos en la estructura física para mantener mejor separación de responsabilidades.

Cada módulo incluye típicamente:
- `domain/` (entidades de dominio)
- `db/` (migraciones/DDL)
- `api/` (endpoints)
- `events/` (schemas JSON)
- `handlers/` (consumo/publicación RabbitMQ)
- `services/`

