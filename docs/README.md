# Kumo Technical Documentation

Kumo is a native macOS client for Mihomo. The first version focuses on a calm daily-use interface, a shared control layer, and an agent-friendly CLI. Advanced networking features remain discoverable, but they are not placed in the primary workflow.

## Domain Map

- [Product](product/README.md) — product scope, daily workflow, and information architecture.
- [Interfaces](interfaces/README.md) — macOS SwiftUI UI, menu/window surfaces, CLI, and agent-control surfaces.
- [Core](core/README.md) — shared control layer, Mihomo runtime, profiles, and generated runtime configuration.
- [Operations](operations/README.md) — app bundle integration, permissions, persistence, logging, and release management.
- [Quality](quality/README.md) — testing strategy, verification commands, and manual QA checklist.
- [Roadmap](roadmap/README.md) — service-mode direction and Sparkle parity tracking.
- [Implementation Standards](standards/README.md) — focused implementation standards that cut across domains.

## Current Source Layout

```text
Sources/
  KumoCoreKit/   Shared domain, runtime, controller, system integration code
  KumoCLIKit/    Reusable CLI commands and rendering
  KumoCLI/       Command-line executable for humans and agents
  KumoApp/       SwiftUI macOS frontend
  KumoService/   Privileged Helper executable and signed socket router
Tests/
  KumoCoreTests/ Shared policy, runtime, service, and integration tests
  KumoCLITests/  CLI contract tests
  KumoAppTests/  Generation-safe app-store tests
```

## Architectural Principle

The GUI, CLI, and privileged Helper backend must share the same domain behavior.
UI surfaces should call `KumoCoreKit` rather than reimplementing Mihomo
lifecycle, profile generation, or system proxy logic.

Production App/CLI runtime mutations use the authenticated Helper backend.
Direct supervisor authority is restricted to the Helper process and isolated
tests; it is not an availability fallback.
