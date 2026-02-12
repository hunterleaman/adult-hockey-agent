# Architecture Decision Records

## Format
Each entry follows:
- **Date**: YYYY-MM-DD
- **Decision**: What was decided
- **Context**: Why it mattered
- **Consequences**: Trade-offs accepted

---

## 2026-02-12: Project Initialization

**Decision**: Use ES modules (type: "module") with NodeNext module resolution

**Context**: Modern Node.js supports ES modules natively. TypeScript's NodeNext resolution provides the best compatibility between CommonJS and ESM.

**Consequences**:
- Must use `.js` extensions in import statements (TypeScript limitation)
- Better tree-shaking and modern tooling support
- Cleaner async/await syntax

---

## 2026-02-12: State Persistence Strategy

**Decision**: JSON file on disk, no database

**Context**: Simple state (session tracking, alert suppression). No complex queries needed. Must survive process restarts.

**Consequences**:
- Atomic write pattern required (write to temp, rename)
- Limited to single-process deployment
- Easy to inspect and debug
- Zero infrastructure dependencies

---

## 2026-02-12: Notification Architecture

**Decision**: Plugin-based notifiers implementing common interface

**Context**: Multiple notification channels needed (Slack, Email, SMS, Push). Users configure only what they want.

**Consequences**:
- Each notifier independently testable
- Easy to add new channels
- Graceful degradation if one channel fails
- Must handle partial failures (some notifiers succeed, others fail)

---
