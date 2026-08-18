# ui/ — Screens, map, widgets

**Owner:** C · **Branch prefix:** `c/` · **Required reviewer:** whoever's flow it touches (CLAUDE.md §3.3)
**Task list:** `Docs/PERSON_C.md`

App shell, navigation, MapLibre GL offline map (`.mbtiles`), layer toggle,
bottom sheet, pins, volunteer ops screens.

**No business logic in widgets** (§5.2). UI reads from the data layer; it never
computes trust, decay or claim IDs. Grouping nearby SOS pins is display-only —
the underlying records stay separate and individually resolvable (§2.1).
