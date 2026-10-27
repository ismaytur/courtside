import SwiftUI
import CourtsideCore

struct ContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    NavigationSplitView {
      Sidebar(model: model).navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
    } detail: {
      GameGrid(model: model)
    }
    .overlay {
      if let playing = model.playing { PlayerOverlay(model: model, playing: playing) }
    }
    .toolbar {
      ToolbarItem {
        Button { Task { await model.checkPier(manual: true) } } label: {
          if model.checkingPier { ProgressView().controlSize(.small) }
          else { Label("Check 720pier", systemImage: "magnifyingglass") }
        }
        .disabled(model.checkingPier || model.refreshing)
        .help("Check 720pier for newly posted games")
      }
      ToolbarItem {
        Button { Task { await model.refresh(force: true) } } label: {
          if model.refreshing { ProgressView().controlSize(.small) }
          else { Label("Refresh schedule", systemImage: "arrow.clockwise") }
        }
        .disabled(model.refreshing)
        .help("Refresh schedule")
      }
    }
    .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
      Button("OK", role: .cancel) {}
    }
  }
}

/// A sidebar line: title, optional count, highlighted when it's the active filter.
struct FilterRow: View {
  let title: String
  var count: Int?
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        Text(title).fontWeight(selected ? .semibold : .regular)
        Spacer()
        if let count { Text("\(count)").monospacedDigit().foregroundStyle(.secondary) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(selected ? Color.accentColor.opacity(0.22) : Color.clear)
  }
}

struct Sidebar: View {
  @Bindable var model: AppModel
  @State private var teamsOpen = false

  var body: some View {
    let leagueCounts = model.counts(by: \.league, ignoring: .league)
    let seasonCounts = model.counts(by: \.season, ignoring: .season)
    let stageCounts = model.counts(by: \.stage, ignoring: .stage)
    List {
      Section("Library") {
        ForEach(Scope.allCases) { s in
          Button { model.scope = s } label: {
            Label(s.rawValue, systemImage: s.icon).fontWeight(model.scope == s ? .semibold : .regular)
              .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowBackground(model.scope == s ? Color.accentColor.opacity(0.22) : Color.clear)
        }
      }
      Section("League") {
        FilterRow(title: "All leagues", count: leagueCounts.values.reduce(0, +), selected: model.league == nil) { model.league = nil }
        ForEach(model.leagues, id: \.id) { l in
          FilterRow(title: l.name, count: leagueCounts[l.id] ?? 0, selected: model.league == l.id) { model.league = l.id }
        }
      }
      Section("Season") {
        ForEach(model.seasons, id: \.self) { s in
          FilterRow(title: s, count: seasonCounts[s] ?? 0, selected: model.season == s) { model.season = s }
        }
      }
      Section("Stage") {
        FilterRow(title: "All stages", count: stageCounts.values.reduce(0, +), selected: model.stage == nil) { model.stage = nil }
        ForEach(model.stages, id: \.key) { st in
          FilterRow(title: st.label, count: stageCounts[st.key] ?? 0, selected: model.stage == st.key) { model.stage = st.key }
        }
      }
      Section {
        DisclosureGroup(isExpanded: $teamsOpen) {
          FilterRow(title: "All teams", selected: model.team == nil) { model.team = nil }
          ForEach(model.teamChoices, id: \.abbr) { t in
            FilterRow(title: t.name, selected: model.team == t.abbr) { model.team = t.abbr }
          }
        } label: {
          Text(model.teamChoices.first { $0.abbr == model.team }?.name ?? "Team").font(.headline)
        }
      }
    }
    .listStyle(.sidebar)
    .onChange(of: model.league) { model.stage = nil; model.team = nil }
  }
}

struct GameGrid: View {
  var model: AppModel
  @State private var lastPrepend = Date.distantPast

  /// Lazy stacks only estimate the height of rows they haven't drawn yet, so the first scroll can land
  /// short; a second one, once the rows in between exist, lands exactly.
  @MainActor private func jump(_ proxy: ScrollViewProxy, _ id: String) async {
    proxy.scrollTo(id, anchor: .top)
    try? await Task.sleep(nanoseconds: 350_000_000)
    proxy.scrollTo(id, anchor: .top)
  }

  var body: some View {
    let series = model.isSeriesView
    let sections = series ? flat(model.seriesView()) : timelineSections(model.timeline())
    let count = model.filtered().count   // same as the sidebar
    let months = series ? [] : monthStarts(model.gameDays())
    GeometryReader { geo in
    // Cards are 240–320 wide with 16 between, inside 20 of padding each side.
    let columns = max(1, Int((geo.size.width - 40 + 16) / (256)))
    ScrollViewReader { proxy in
      ScrollView {
        if let note = model.pierNote {
          HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(note)
            Spacer()
            Button("Dismiss") { model.pierNote = nil }.buttonStyle(.link)
          }
          .padding(12)
          .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          .padding(.horizontal, 20).padding(.top, 12)
        }
        if sections.isEmpty {
          ContentUnavailableView(model.refreshing ? "Loading the schedule…" : "No games here",
                                 systemImage: "sportscourt",
                                 description: Text(model.refreshing ? "This takes a few seconds the first time." : "Try other filters, or refresh the schedule."))
            .padding(.top, 120)
        } else {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            // Reaching the top loads the 5 game days before; the day you were looking at stays put.
            if !series && model.canLoadEarlier {
              ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
                .onAppear {
                  guard Date().timeIntervalSince(lastPrepend) > 0.5, let keep = sections.first?.id else { return }
                  lastPrepend = Date()
                  model.loadEarlier()
                  Task { @MainActor in
                    // Twice: the first pass lands on estimated heights of the new days above.
                    for _ in 0..<2 {
                      var t = Transaction(); t.disablesAnimations = true
                      withTransaction(t) { proxy.scrollTo(keep, anchor: .top) }
                      try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                  }
                }
            }
            ForEach(sections) { DaySection(model: model, section: $0, columns: columns) }
            // Reaching the bottom loads the next 5 game days.
            if !series && model.canLoadLater {
              ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(8)
                .onAppear { model.loadLater() }
            }
          }
        }
      }
      .navigationTitle("Courtside")
      .navigationSubtitle("\(count) game\(count == 1 ? "" : "s")")
      .onChange(of: model.filterKey) {
        model.resetTimeline()
        if let first = model.timeline().first { Task { await jump(proxy, first.id) } }
      }
      .toolbar {
        ToolbarItem {
          Button {
            model.resetTimeline()
            if let first = model.timeline().first { Task { await jump(proxy, first.id) } }
          } label: { Label("Today", systemImage: "calendar.badge.clock") }
            .disabled(series || sections.isEmpty)
            .help("Back to the next games")
        }
        ToolbarItem {
          Menu {
            ForEach(months, id: \.self) { day in
              Button(AppModel.monthTitle(String(day.prefix(7)))) {
                model.resetTimeline(to: day)
                if let first = model.timeline().first { Task { await jump(proxy, first.id) } }
              }
            }
          } label: { Label("Jump to month", systemImage: "calendar") }
            .disabled(series || months.isEmpty)
            .help("Jump to month")
        }
      }
    }
    }
  }
}

/// First game day of each month, for "Jump to month".
private func monthStarts(_ days: [String]) -> [String] {
  var seen = Set<String>()
  return days.filter { seen.insert(String($0.prefix(7))).inserted }
}

/// One sticky section. SwiftUI doesn't stack nested pinned headers, so the month and the day share
/// one header ("October 2026 · Mon 26 Oct"); the first loaded day of a month opens with a month banner.
struct FlatSection: Identifiable {
  let id: String
  let month: String
  let day: String
  let banner: String?
  let games: [Game]
}

/// Timeline days, oldest first; a banner wherever the month changes.
@MainActor private func timelineSections(_ days: [DayGroup]) -> [FlatSection] {
  var lastMonth = ""
  return days.map { d in
    let ym = String(d.id.prefix(7)), month = AppModel.monthTitle(ym)
    defer { lastMonth = ym }
    return FlatSection(id: d.id, month: month, day: d.title, banner: ym != lastMonth ? month : nil, games: d.games)
  }
}

/// Series view: one section per matchup.
private func flat(_ blocks: [Block]) -> [FlatSection] {
  blocks.flatMap { b in
    b.days.map { d in FlatSection(id: b.id + "/" + d.id, month: b.title, day: d.title, banner: nil, games: d.games) }
  }
}

struct DaySection: View {
  var model: AppModel
  let section: FlatSection
  let columns: Int

  var body: some View {
    Section {
      Color.clear.frame(height: 0).id(section.id)   // scroll target ("Today", month, keep-in-place)
      if let banner = section.banner {
        Text(banner).font(.title.bold()).padding(.horizontal, 20).padding(.top, 8)
      }
      // Plain rows, not a lazy grid: a day has at most ~15 games, and exact heights keep
      // "load earlier" and the jumps landing where they should.
      VStack(alignment: .leading, spacing: 16) {
        ForEach(Array(stride(from: 0, to: section.games.count, by: columns)), id: \.self) { i in
          let row = section.games[i..<min(i + columns, section.games.count)]
          HStack(alignment: .top, spacing: 16) {
            ForEach(row) { GameCard(model: model, game: $0).frame(maxWidth: .infinity) }
            ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
          }
        }
      }
      .padding(.horizontal, 20).padding(.bottom, 12)
    } header: {
      StickyHeader(month: section.month, day: section.day)
    }
  }
}

struct StickyHeader: View {
  let month: String
  let day: String
  var body: some View {
    HStack(spacing: 8) {
      Text(month).font(.headline)
      if !day.isEmpty { Text("·").foregroundStyle(.secondary); Text(day).font(.headline).foregroundStyle(.secondary) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20).padding(.vertical, 8)
    .background(.bar)
  }
}
