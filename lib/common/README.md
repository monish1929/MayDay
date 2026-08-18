# common/ — Shared utilities only

Formatting, small helpers, constants. **Resist putting logic here** (CLAUDE.md §5.2).

If something feels like it belongs in `common/`, it usually belongs in `data/`
behind a named function instead. A shared helper with a `ClaimType` conditional
inside it is how the two claim-ID paths get accidentally reunited (§2.1).
