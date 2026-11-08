# ResilientSteps Architecture Decision Record (ADR) + System Specification

> **Legacy document — superseded.** This records the original "CityOS" platform
> vision. The current product is **ResilientSteps**, focused on safety- and
> comfort-aware walking navigation. See `docs/README.md` for the live roadmap.

Version: 0.1 (Foundational Blueprint)

> This document captures architectural decisions, implementation
> constraints, deployment philosophy, and module specifications for
> ResilientSteps.

------------------------------------------------------------------------

# 1. Vision

## Mission

ResilientSteps is a civic operating platform that enables citizens to report
public infrastructure, sanitation, and safety issues while providing
municipalities with actionable dashboards and map-based analytics.

## Product Philosophy

-   The walking navigator becomes one module inside the broader platform.
-   Platform first, application second.
-   Cloud-agnostic.
-   Deployable locally for demos.
-   Configuration over hardcoding.
-   Scheduled recomputation over expensive real-time processing.
-   AI is optional rather than foundational.

------------------------------------------------------------------------

# 2. Core Modules

1.  ResilientSteps
2.  Infrastructure Reporting
3.  Waste Management
4.  Civic Analytics
5.  Administration Dashboard
6.  Deployment Framework

------------------------------------------------------------------------

# 3. Architecture Decisions (ADR)

## ADR-001

Decision: Use FastAPI + Flutter + PostGIS + Valhalla.

Reason: Existing stack is mature and reusable.

------------------------------------------------------------------------

## ADR-002

Decision: Use H3 as the canonical spatial aggregation layer.

Reason: Supports scalable heatmaps and locality-based recomputation.

------------------------------------------------------------------------

## ADR-003

Decision: User classifies reports.

Reason: Removes recurring AI inference cost.

------------------------------------------------------------------------

## ADR-004

Decision: Infrastructure heatmaps regenerate every 36--48 hours.

Reason: Municipal infrastructure changes slowly.

------------------------------------------------------------------------

## ADR-005

Decision: Safety routing refresh every 6 hours.

Reason: Pedestrian safety benefits from more frequent updates.

------------------------------------------------------------------------

## ADR-006

Decision: Hourly ingestion of reports.

Reason: Authorities should receive reasonably fresh information without
excessive compute.

------------------------------------------------------------------------

## ADR-007

Decision: Deployment profiles control runtime behaviour.

Profiles: - local - demo - aws - production

------------------------------------------------------------------------

# 4. High-Level System

Citizen App → API → Database → Scheduled Workers → Heatmaps → Dashboard

------------------------------------------------------------------------

# 5. Data Model (Initial)

Entities

-   User
-   Report
-   Image
-   H3Cell
-   Municipality
-   Moderator
-   HeatmapSnapshot

Report lifecycle

Submitted → Pending → Verified → Aggregated → Archived

------------------------------------------------------------------------

# 6. Report Categories

Infrastructure - pothole - streetlight - footpath - obstruction -
traffic signal - water leak - flooding

Waste - overflowing bin - dumping - debris - burning - dead animal

Safety - harassment - suspicious activity - stray animals - poor
lighting

------------------------------------------------------------------------

# 7. Scheduled Jobs

Hourly - ingest reports

Every 6 hours - routing refresh

Every 36--48 hours - infrastructure recomputation - regenerate H3
GeoJSON

Weekly - analytics

------------------------------------------------------------------------

# 8. Deployment Profiles

## local

-   Docker Compose
-   Local storage
-   ngrok tunnel
-   seeded data

## demo

-   Docker Compose
-   mock users
-   prebuilt heatmaps

## aws

-   EC2/ECS
-   S3
-   Supabase

## production

-   CloudFront
-   Monitoring
-   Backups

------------------------------------------------------------------------

# 9. Configuration

Everything configurable:

-   city.yaml
-   scoring.yaml
-   deployment.yaml
-   cron.yaml

No deployment-specific code.

------------------------------------------------------------------------

# 10. Demo Mode

One command should:

-   migrate database
-   seed demo users
-   seed reports
-   upload images
-   generate heatmaps
-   start services

------------------------------------------------------------------------

# 11. Future Expansion

-   Multi-city support
-   Department workflows
-   SLA tracking
-   Predictive maintenance
-   Optional AI summaries
-   Open civic API

------------------------------------------------------------------------

# 12. Implementation Roadmap

Phase 1 - Refactor ResilientSteps into module

Phase 2 - Infrastructure reporting

Phase 3 - Waste reporting

Phase 4 - Dashboard

Phase 5 - Deployment framework

Phase 6 - Multi-city support

------------------------------------------------------------------------

# Appendix

## Design Principles

-   Modular
-   Cloud agnostic
-   Configuration driven
-   Container first
-   Low operational cost
-   Easy hackathon deployment
-   Production migration without rewrites

## Living Document

This specification is intended to evolve alongside implementation and
serve as the project's single source of truth.
