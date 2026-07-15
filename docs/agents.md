# Agent Path Index

Quick reference for AI agents working on this codebase. Each entry maps a
task category to the canonical document or command that owns it.

## Release

**SOP:** [docs/operations/release-management.md](operations/release-management.md)

Key commands:

```bash
# Kumo releases are Apple Silicon arm64 only.
make clean
make release-dmg VERSION=0.0.10 \
  DEVELOPMENT_TEAM="$APPLE_DEVELOPMENT_TEAM" \
  CODE_SIGN_IDENTITY="$APPLE_CODE_SIGN_IDENTITY" \
  NOTARY_KEY_PATH="$APPLE_NOTARY_KEY_PATH" \
  NOTARY_KEY_ID="$APPLE_NOTARY_KEY_ID" \
  NOTARY_ISSUER_ID="$APPLE_NOTARY_ISSUER_ID"

git tag -a "0.0.10" -m "Kumo 0.0.10"
git push origin "0.0.10"
gh run list --workflow build-release.yml --limit 1
```

The release command fails unless the App, Helper, CLI, and bundled Node are
exactly arm64; Kumo-owned binaries must use hardened-runtime Developer ID
Application signing from one Team. The DMG is signed, notarized, stapled, and
only then hashed into `latest.yml`.

**Never forget:** verify the workflow uploaded `latest.yml`. The in-app update
checker will 404 without it.

**Verify URLs:**

```bash
curl -sI "https://github.com/ProjectKumo/KumoApp/releases/latest/download/latest.yml"
```

## Update Runtime Behavior

**Docs:** [docs/operations/app-updates/README.md](operations/app-updates/README.md)

- Feed URLs, manifest contract, polling logic, notifications, installer helper.
- `AppUpdateManager` in `Sources/KumoCoreKit/Support/AppUpdateManager.swift`.
- Apple Silicon uses the single `latest.yml` feed. Intel builds and feeds are
  intentionally unsupported.

## Domain Reference

| Area | Document |
|------|----------|
| Product scope | [product/README.md](product/README.md) |
| UI surfaces (SwiftUI, CLI, agent control) | [interfaces/README.md](interfaces/README.md) |
| Control layer, Mihomo runtime, profiles | [core/README.md](core/README.md) |
| App packaging, permissions, persistence, logging, releases | [operations/README.md](operations/README.md) |
| Testing strategy | [quality/README.md](quality/README.md) |
| Service-mode direction, Sparkle parity | [roadmap/README.md](roadmap/README.md) |
| Cross-domain implementation standards | [standards/README.md](standards/README.md) |

## Source Layout

```
Sources/
  KumoCoreKit/   Shared domain, runtime, controller, system integration
  KumoCLI/       Command-line frontend
  KumoApp/       SwiftUI macOS frontend
Tests/
  KumoCoreTests/ Unit tests for the shared control layer
```

## Common Commands

```bash
make app              # Debug build
make dev              # Quit, clean debug, build, and open
make test             # Run unit tests
make clean            # Remove all build artifacts
make release-dmg VERSION=x.y.z  # signed, notarized arm64 release
```

## Decision Records

ADRs live in [decisions/](decisions/):

- [ADR-001](decisions/ADR-001-dns-sniffer-decoupling.md) — DNS/Sniffer decoupling
- [ADR-002](decisions/ADR-002-policy-value-types.md) — Policy value types
- [ADR-003](decisions/ADR-003-hosts-top-level-vs-nested.md) — Hosts top-level vs nested
- [ADR-004](decisions/ADR-004-restart-vs-patch-for-dns-sniffer.md) — Restart vs patch for DNS/Sniffer
