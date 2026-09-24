# PORT_PLAN — Ice's Menu-Bar-Icon-Management in Vorssaint einbauen

**Ziel:** Menu-Bar-Icons anderer Apps sortieren/verstecken/gruppieren
(Bartender-Feature) als neues Vorssaint-Utility, portiert aus
[jordanbaird/Ice](https://github.com/jordanbaird/Ice) (GPL-3.0, kompatibel).

**Fork:** https://github.com/CH4RL3I/vorssaint-utils
**Upstream:** https://github.com/vorssaint/vorssaint-utils
**Upstream-Issue:** https://github.com/vorssaint/vorssaint-utils/issues/1887

## Zahlen

| | LOC | Files |
|---|---:|---:|
| Vorssaint total | 237.705 | (~600+) |
| — davon Services | 119.260 | |
| — davon UI | 60.120 | |
| — davon Core | 51.496 | |
| Ice total | 18.156 | |
| **Ice `MenuBar/` (Port-Ziel)** | **6.597** | **20** |

Port = ~2.8 % Zuwachs zu Vorssaint. Keine Neuentwicklung, kein Reverse-Eng.

## Ice `MenuBar/` — was rein muss

| Subdir | LOC | Zweck |
|---|---:|---|
| `MenuBarItems/` | 2.419 | Icon-Enumeration, Positionierung, Drag-Reorder |
| `Appearance/` | 1.047 | Optische Customization (Spacing, Farben) |
| `ControlItem/` | 754 | "Always-Hidden" / "Hidden" Sektionen-Trenner |
| `Appearance/MenuBarAppearanceEditor/` | 649 | UI zum Konfigurieren |
| `Search/` | 469 | Icon-Suche |
| `Appearance/Configurations/` | 315 | Preset-Konfigurationen |
| `Spacing/` | 215 | Spacing-Modifier |
| `MenuBarManager.swift` + `MenuBarSection.swift` | ~730 | Root-Koordinator |

Zusätzlich aus Ice übernehmen: `Ice/Swizzling/NSSplitViewItem+swizzledCanCollapse.swift` (macOS-Internal-API-Hook, wenige LOC aber ohne den kein Reorder).

## Zielort in Vorssaint

Vorssaints Architektur (aus Sources/Vorssaint/):
- **`Services/`** — 119k LOC Business-Logic (Feature-Backends)
- **`UI/`** — 60k LOC SwiftUI-Panels
- **`Core/`** — 51k LOC Shared

Integration:
1. Neuer Service: `Sources/Vorssaint/Services/MenuBarManager/` (aus Ice's `MenuBar/` + `MenuBarManager.swift` + `MenuBarSection.swift`)
2. Neues UI-Panel: `Sources/Vorssaint/UI/MenuBarManager/` (Ice's Editor-UI in Vorssaints Panel-Style)
3. Feature-Flag: `featureAvailable.menuBarManager = 1` in Defaults ergänzen
4. Bundle-ID beibehalten (`com.vorssaint.utils.dev` bei `--dev` builds) — koexistiert mit offizieller App

## Nicht übernehmen

- Ice's `Settings/`, `Updates/`, `UserNotifications/` — Vorssaint hat eigene Äquivalente
- Ice's `Permissions/` — Vorssaint managed macOS-Permissions zentral
- Ice's App-Entry (`Main/`) — Vorssaint hat eigenen main.swift

## Update-Strategie

- `origin` = Fork (`CH4RL3I/vorssaint-utils`)
- `upstream` = offiziell (`vorssaint/vorssaint-utils`)
- Nach jedem Vorssaint-Release: `git fetch upstream && git merge upstream/main` — Konflikte nur in unseren neuen `MenuBarManager/`-Ordnern (sollten selten sein wenn Vorssaint das Feature NICHT selbst baut)
- Wenn Vorssaint selbst das Feature merged (Issue #1887) → Fork obsolet, zurück auf offizielle App

## Signing / Distribution

- `build.sh --dev` erzeugt "Vorssaint (Developer)"-Variante — läuft ohne Notarisierung lokal
- Für "richtige" Distribution (wie brew cask): Apple Developer Account ($99/Jahr) + Notarisierung nötig
- Zwischen-Lösung: unsigned .app + `spctl --add` manuell erlauben pro Mac

## Aufwand-Schätzung (nur Port, kein Neu-Design)

| Phase | Stunden |
|---|---:|
| Ice `MenuBar/` verstehen (6.6k LOC lesen) | 15-25 |
| Adapter-Layer Ice→Vorssaint schreiben | 20-30 |
| UI-Panel im Vorssaint-Style umbauen | 15-25 |
| Testing (macOS 14/15/26, mit vielen Icon-Apps) | 10-15 |
| Signing/Notarisierung setup | 5-10 |
| Build-Pipeline für Fork | 5-10 |
| **Gesamt** | **70-115** |

## Risiken / Realitätscheck

1. **Vorssaint-Codebase ist ungewöhnlich groß für Alter des Repos.** 237k Swift-LOC in 3 Monaten (Repo seit Juni 2026 public) = ~2600 LOC/Tag konsistent. Kann sein: internes Projekt public gemacht + Massen-KI-Code + Solo-Superhero. Nichts alarmierend, aber unbekannter Terrain.
2. **Alle merged PRs vom Maintainer selbst** — 5/5 letzte. Wenn Upstream unser Feature-PR bekäme, Chance auf Merge unklar. Fork bleibt möglicherweise dauerhaft nötig.
3. **macOS-Menu-Bar-API ist private** — Ice nutzt Swizzling (NSSplitViewItem-Hook). Bei macOS-Updates kann das brechen. Ice's Maintainer fixt das für Ice; wir müssten es für unseren Fork parallel tracken.
4. **Zeit-Rechnung:** Wenn Upstream in 4 Wochen selbst das Feature baut (was der Maintainer schnell tut, siehe seine PR-Frequenz), wäre unser Fork zu spät. Realistischer Cost/Benefit: **Fork nur starten wenn wir 6+ Wochen keine Reaktion sehen.**

## Nächste konkrete Schritte

- [ ] `swift build` versuchen — sicherstellen dass Fork lokal kompiliert bevor was verändert wird
- [ ] `swift build --configuration release` und `./build.sh --dev` durchprobieren
- [ ] Ice `MenuBar/MenuBarManager.swift` + `MenuBarSection.swift` lesen (~730 LOC, Einstiegspunkt)
- [ ] Vorssaint's Panel-System skizzieren (wie hängt sich ein neues Utility ins Vorssaint-UI?)
- [ ] Entscheidungspunkt nach Phase 1: **weitermachen oder Upstream-Reaktion abwarten?**
