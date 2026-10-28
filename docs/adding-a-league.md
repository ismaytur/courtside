# Adding a league

A league plug-in answers *what games exist*: its seasons, stages, teams and schedule. Where to get a
game's video is a source's job ([adding-a-source.md](adding-a-source.md)), wired to the league in its
own file. NBA is the only league today; here's how to add another (say EuroLeague).

## 1. Conform to `League`

Create `Sources/CourtsideCore/Leagues/<id>/<Name>.swift` with a type conforming to `League`
(`Leagues/League.swift`):

```swift
public protocol League: Sendable {
  var id: String { get }          // "euroleague": folder names, game IDs, the settings key
  var name: String { get }        // "EuroLeague"
  var stages: [Stage] { get }     // in season order, for the sidebar filter
  func season(on date: Date) -> String                 // e.g. "2026-27"
  func teams() async throws -> [Team]
  func schedule(season: String, teams: [Team], now: Date) async throws -> [ScheduledGame]
}
```

- `teams()` returns each `Team` with its abbreviation (used in game IDs), names, colors and a
  `logoURL` (downloaded once by `Logos`).
- `schedule(...)` returns `ScheduledGame`s. Each needs a stable `externalID` (the provider's id, so a
  moved game is updated, not duplicated), the league-local `date`, the teams, the stage and, for
  playoffs, a `gameNumber`. Fetch over `Web.*`, never `URLSession` directly. **Never include scores.**
- See `Leagues/NBA/NBA.swift` for a worked example (ESPN's site API, season types → stages, UTC →
  local date).

## 2. Register it

Add it to `Leagues.all` in `Leagues/League.swift`. It then appears in the sidebar and in Settings
(leagues can be switched off there; missing = on). The database is shared — every game row carries
its `league`, so nothing in `DB/` changes.

## 3. Wire a source to it

A source (e.g. 720pier) usually carries several leagues. Add a `Leagues/<id>/<Name>+<Source>.swift`
that says which parts of the source hold this league's games and how to match a listing to a
scheduled game (by date + teams). `NBA+720pier.swift` is the model: it names the forums, maps full
team names to abbreviations (with aliases for the forum's spellings), computes the "missing" games,
and walks pages until they're found.

## Checklist

- [ ] `id` is lowercase and stable (folders, game IDs, settings key)
- [ ] `season(on:)`, `stages`, `teams()`, `schedule(...)` implemented; all HTTP via `Web.*`
- [ ] `externalID` is stable; game dates are the league's local day; **no scores**
- [ ] added to `Leagues.all`
- [ ] a `+<Source>` file matches its games on a source, with tests over saved fixtures
