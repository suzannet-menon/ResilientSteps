# ResilientSteps Engineering Handbook

> **Legacy document — superseded.** This is the original "CityOS" platform
> handbook. The current product is **ResilientSteps**, focused on safety- and
> comfort-aware walking navigation. See `docs/README.md` for the live roadmap.

# Volume I --- Vision, Product & Functional Specification

**Version:** 0.1 Draft\
**Status:** Living Document

------------------------------------------------------------------------

# Table of Contents

1.  Executive Summary
2.  Vision
3.  Problem Statement
4.  Product Philosophy
5.  Design Principles
6.  Stakeholders
7.  User Personas
8.  Product Modules
9.  Functional Requirements
10. Non-functional Requirements
11. User Journeys
12. Deployment Philosophy
13. Success Metrics
14. Roadmap

------------------------------------------------------------------------

# 1. Executive Summary

ResilientSteps is a civic operating platform that enables citizens to report
infrastructure, waste management and public safety issues while giving
municipal authorities real-time visibility and scheduled city-wide
analytics.

The walking navigator becomes the first module of the broader platform instead
of the entire product.

The platform is designed to be:

-   cloud agnostic
-   inexpensive to operate
-   containerized
-   configurable
-   reproducible
-   deployable for hackathons in minutes

------------------------------------------------------------------------

# 2. Vision

## Mission

Empower citizens to become the city's distributed sensor network while
enabling municipal authorities to prioritize maintenance using
geospatial intelligence.

## Long-term Goal

Instead of replacing existing municipal software, ResilientSteps becomes an
operational layer capable of ingesting citizen reports and transforming
them into actionable city-wide insights.

------------------------------------------------------------------------

# 3. Problem Statement

Current civic reporting systems generally suffer from:

-   fragmented complaint portals
-   poor visualisation
-   little spatial analysis
-   limited transparency
-   poor usability
-   siloed departments

Citizens rarely know whether problems around them are isolated or
systemic.

Authorities rarely receive spatially aggregated intelligence suitable
for planning.

------------------------------------------------------------------------

# 4. Product Philosophy

ResilientSteps follows several guiding principles.

## Configuration over Code

Cities should be deployable by changing configuration files.

## Scheduled Computation

Heavy processing belongs in scheduled workers rather than request paths.

## Cloud Agnostic

The same application should run on:

-   laptop
-   Docker Compose
-   EC2
-   ECS

without code changes.

## Platform First

ResilientSteps is a module.

Infrastructure reporting is a module.

Waste reporting is a module.

Future modules should integrate naturally.

------------------------------------------------------------------------

# 5. Design Principles

-   Simplicity over novelty
-   Low operational cost
-   Clear separation of concerns
-   Modular architecture
-   API-first backend
-   Mobile-first experience
-   Open standards
-   Extensible data model
-   Reproducible deployments

------------------------------------------------------------------------

# 6. Stakeholders

## Citizens

Submit reports, navigate safely and view community issues.

## Municipal Officers

Review reports, verify submissions and monitor dashboards.

## Moderators

Verify incoming reports before aggregation.

## Administrators

Manage deployments, users and configuration.

------------------------------------------------------------------------

# 7. User Personas

### Student

Reports broken lighting while walking home.

### Resident

Reports overflowing garbage bins and potholes.

### Municipal Engineer

Uses dashboards to prioritise repairs.

### Commissioner

Reviews ward-wise analytics and planning reports.

### Hackathon Judge

Launches a complete demo environment from seeded data.

------------------------------------------------------------------------

# 8. Product Modules

## ResilientSteps

Safety-first pedestrian routing.

## Infrastructure

Potholes, footpaths, traffic signals, lighting, flooding.

## Waste Management

Overflowing bins, dumping, debris, dead animals.

## Civic Analytics

Ward dashboards, trends and heatmaps.

## Administration

Moderation, verification and operational tools.

## Deployment Framework

Local, Demo, AWS and Production deployment profiles.

------------------------------------------------------------------------

# 9. Functional Requirements

## Citizen

-   Register/Login
-   Submit report
-   Attach image
-   Select category
-   Select severity
-   View nearby reports
-   View infrastructure heatmap
-   Safe pedestrian routing
-   SOS

## Authority

-   View incoming reports
-   Filter by category
-   Filter by ward
-   Verify reports
-   Export reports
-   View analytics

## Administrator

-   Manage users
-   Manage deployment configuration
-   Trigger scheduled jobs
-   View system health

------------------------------------------------------------------------

# 10. Non-functional Requirements

Performance

-   Responsive UI
-   Background processing
-   Cached heatmaps

Scalability

-   Modular services
-   Containerised deployment
-   H3 aggregation

Maintainability

-   YAML configuration
-   Clear module boundaries
-   Architecture Decision Records

Availability

-   Demo capable without cloud
-   Optional cloud deployment

------------------------------------------------------------------------

# 11. User Journeys

## Reporting

Citizen → Capture photo → Choose category → Choose severity → Submit

Authority → Verify → Scheduled aggregation → Heatmap update

## ResilientSteps

Origin → Destination → Safe route → Navigation → Arrival

------------------------------------------------------------------------

# 12. Deployment Philosophy

Profiles

-   Local
-   Demo
-   AWS
-   Production

Every deployment profile changes infrastructure only.

Business logic remains identical.

------------------------------------------------------------------------

# 13. Success Metrics

Citizen Metrics

-   reports submitted
-   verified reports
-   repeat contributors

Operational Metrics

-   report verification time
-   infrastructure score
-   heatmap generation duration

Platform Metrics

-   deployment time
-   uptime
-   API latency

Hackathon Metrics

-   one-command deployment
-   seeded demo
-   reproducibility

------------------------------------------------------------------------

# 14. Initial Roadmap

Phase 1

ResilientSteps modularisation

Phase 2

Infrastructure reporting

Phase 3

Waste management

Phase 4

Authority dashboard

Phase 5

Deployment framework

Phase 6

Multi-city support

Phase 7

Optional AI summaries

------------------------------------------------------------------------

# Closing Notes

Volume I intentionally focuses on product vision, stakeholders,
requirements, and guiding architectural philosophy.

Subsequent volumes will specify backend architecture, database schemas,
API contracts, frontend implementation, deployment pipelines, testing
strategy, and operations in implementation-level detail.

This handbook is intended to become the authoritative specification for
ResilientSteps.
