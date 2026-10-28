# Adding a source

A source answers *where to get a game's video*: it signs in to a site, reads its listings, and finds
the `.torrent` for a game. A league ([adding-a-league.md](adding-a-league.md)) answers *what games
exist*. One source can serve several leagues, so a source knows nothing about the NBA by itself; the
league-to-source wiring lives in the league's `+<Source>` file. 720pier is the only source today.

## 1. Conform to `Source`

Create `Sources/CourtsideCore/Sources/<Name>.swift` conforming to `Source`
(`Sources/Source.swift`):

```swift
public protocol Source: Sendable {
  var id: String { get }        // "720pier": the settings key for its login
  var name: String { get }      // "720pier.ru"
  var homepage: URL { get }
}
```

Give it whatever else it needs — sign-in, listing parsing, a topic → `.torrent` lookup. `Pier720`
(an `actor`) is the model:

- **All HTTP goes through `Web.*`** (`text`, `data`, `postForm`), never `URLSession`. Cookies persist
  across calls in `fetch(_:)`, so a sign-in sticks. That one file, `Web/Fetch.swift`, is the user's —
  don't change its insides.
- **Sign-in** reads the login form's hidden fields and posts them with the account from
  `Settings.sources[id]`. Log each step with `Log` (`720pier` area); secrets are redacted centrally.
- **Parsing is pure and tested offline** against `Tests/CourtsideCoreTests/Fixtures/`. **Never request
  the live site from code or tests.**
- The torrent is resolved per game when it's actually played, not during the listing sweep.

> 720pier blocks programs (403 to plain requests). Getting past its bot protection is the user's own
> work inside `Fetch.swift`. Don't build or debug a bypass.

## 2. Credentials

If the site needs a login, it comes from `Settings.sources["<id>"]` (username/password), edited in
the app's Settings. Never hard-code or log credentials.

## 3. Wire it to a league

In the league's `Leagues/<league>/<Name>+<Source>.swift`: name the parts of the site that hold that
league's games, and match a listing to a scheduled game by date + both teams (map the site's team
spellings to abbreviations, with aliases as needed). See `NBA+720pier.swift`: it picks the forums,
finds the games the library is missing, and walks pages newest-first until they're all found or the
pages are older than the oldest missing game.

## Checklist

- [ ] `id` is stable (settings key)
- [ ] all HTTP via `Web.*`; parsing is pure
- [ ] credentials only from `Settings.sources`, never logged
- [ ] tests parse saved fixtures; no live requests in code or tests
- [ ] a league's `+<Source>` file matches its games and records the topic URL via `library.setFound(...)`
