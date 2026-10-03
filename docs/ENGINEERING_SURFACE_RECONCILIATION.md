# Surface Reconciliation Contract

Before release, exercise the exact candidate through the actual Mirror Manager / operator CLI on an approved lab mirror host.

- Confirm status, validation, preparation, and recovery menu/command surfaces match the runbook.
- Exercise only read-only or explicitly safe preparation paths unless the lab target and rollback snapshot are authorized.
- Confirm operator messages, readiness state, and next-action guidance remain consistent.
- Record candidate SHA, lab host identity, exercised operator path, PASS/FAIL, and evidence.

Unit/static tests alone do not satisfy this surface check.

## Engineering System User Acceptance v2 — mandatory execution semantics

This repository-local contract inherits the portable semantics from
`datarelay-labs/engineering-system@fb431381ef4c49851fc40b683e8bad22607e7e0c/standards/USER_ACCEPTANCE.md`.
The project-specific scenarios above remain authoritative for this product; the rules below are additional mandatory execution rules.

- **ChatGPT itself is the executor and final auditor.** ChatGPT directly acts as the applicable real User/Operator/Admin persona and drives the actual supported public surface. A coding agent, alternate model, wrapper, scripted replay, CI job, unit/component/API suite, or static scanner is supporting evidence only and cannot produce Surface Reconciliation PASS.
- Start **feature-first and black-box-first**. Build/confirm the supported capability inventory, then let the acting persona discover each applicable capability from the public UI/CLI/help/navigation/error/output. Do not preload source code, test code, internal routes/catalogs, hidden APIs, implementation details, or a scenario answer key into the acting persona.
- After a surface's public evidence is frozen, post-hoc source/config/parser/route/static inspection may be used by the auditor to find hidden, duplicate, stale, orphaned, or undiscoverable surfaces. Auditor knowledge must not be fed back as prior knowledge to the persona.
- Reconcile every applicable capability through discovery, role/context, terminology, state/empty/error semantics, next action, recovery guidance, and destructive/risky-action safety. Every mandatory capability and public control must receive an explicit disposition; blocked/partial/not-run is never silently converted to PASS.
- **A finding is not a stop condition.** Preserve it and continue every safe independent scenario. Do not patch product/source/contract during the frozen discovery pass. After all safe executable checks are exhausted, freeze the complete finding set, remediate it as one bounded batch, then start a new run from the beginning.
- Use the actual primary surface. Browser projects require a real Chromium/Chrome process driven by ChatGPT; CLI projects require the actual supported public CLI/TUI. jsdom/component/API/static checks and automation harnesses do not substitute for the user action.
- Retain exact candidate HEAD, committed contract identity/digest, scenario/findings ledgers, and ledger-derived summary. Release PASS requires 100% applicable capability/public-surface coverage, zero mandatory FAIL/PARTIAL/BLOCKED, zero unresolved blocking finding, and clean exact-HEAD evidence.
- If the product explicitly supports an AI-assisted user path, mirror the same user goal through that path using only information visible to the user and require semantically equivalent supported guidance/outcome.
