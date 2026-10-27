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

  /// Lazy stacks only estimate the height of rows they haven't drawn yet, so the first scroll can land
  /// short; a second one, once the rows in between exist, lands exactly.
  @MainActor private func jump(_ proxy: ScrollViewProxy, _ id: String) async {
    proxy.scrollTo(id, anchor: .top)
    try? await Task.sleep(nanoseconds: 350_000_000)
    proxy.scrollTo(id, anchor: .top)
  }

  var body: some View {
    let blocks = model.blocks()
    let count = model.filtered().count   // same as the sidebar, including upcoming games not shown yet
    let monthBlocks: [Block] = model.isSeriesView ? [] : blocks
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
        if blocks.isEmpty {
          ContentUnavailableView(model.refreshing ? "Loading the schedule…" : "No games here",
                                 systemImage: "sportscourt",
                                 description: Text(model.refreshing ? "This takes a few seconds the first time." : "Try other filters, or refresh the schedule."))
            .padding(.top, 120)
        } else {
          LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
            ForEach(flat(blocks)) { DaySection(model: model, section: $0) }
          }
        }
      }
      .navigationTitle("Courtside")
      .navigationSubtitle("\(count) game\(count == 1 ? "" : "s")")
      .toolbar {
        ToolbarItem {
          Menu {
            ForEach(monthBlocks) { b in
              Button(b.title) { Task { await jump(proxy, b.id) } }
            }
          } label: { Label("Jump to month", systemImage: "calendar") }
            .disabled(model.isSeriesView || blocks.isEmpty)
            .help("Jump to month")
        }
      }
    }
  }
}

/// One sticky section. SwiftUI doesn't stack nested pinned headers, so the month and the day share
/// one header ("October 2026 · Mon 26 Oct"); the first day of a month also opens with a month banner.
/// Upcoming has no banner: its header right above would say "Upcoming" a second time.
struct FlatSection: Identifiable {
  let id: String
  let blockID: String
  let month: String
  let day: String
  let first: Bool            // first section of its block (the "Jump to" target)
  let banner: String?        // block title, on its first section only
  let games: [Game]
  let laterCount: Int        // "show more upcoming" button, on the last upcoming section
}

private func flat(_ blocks: [Block]) -> [FlatSection] {
  blocks.flatMap { b in
    b.days.enumerated().map { i, d in
      FlatSection(id: b.id + "/" + d.id, blockID: b.id, month: b.title, day: d.title, first: i == 0,
                  banner: i == 0 && !d.title.isEmpty && b.id != "upcoming" ? b.title : nil,
                  games: d.games, laterCount: i == b.days.count - 1 ? b.laterCount : 0)
    }
  }
}

struct DaySection: View {
  var model: AppModel
  let section: FlatSection

  var body: some View {
    Section {
      if let banner = section.banner {
        Text(banner).font(.title.bold()).padding(.horizontal, 20).padding(.top, 8).id(section.blockID)
      } else if section.first {
        Color.clear.frame(height: 0).id(section.blockID)   // "Jump to" target without a banner
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)], spacing: 16) {
        ForEach(section.games) { GameCard(model: model, game: $0) }
      }
      .padding(.horizontal, 20).padding(.bottom, 12)
      if section.laterCount > 0 {
        Button(model.showLaterUpcoming ? "Hide later games" : "Show \(section.laterCount) more upcoming games") {
          model.showLaterUpcoming.toggle()
        }
        .padding(.horizontal, 20)
      }
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
