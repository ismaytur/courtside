import SwiftUI
import CourtsideCore

struct ContentView: View {
  @Bindable var model: AppModel

  var body: some View {
    NavigationSplitView {
      Sidebar(model: model).navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    } detail: {
      GameGrid(model: model)
    }
    .toolbar {
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

struct Sidebar: View {
  @Bindable var model: AppModel

  var body: some View {
    List(selection: $model.scope) {
      Section("Library") {
        ForEach(Scope.allCases) { s in Label(s.rawValue, systemImage: s.icon).tag(s) }
      }
      Section("Filter") {
        picker("League", $model.league, model.leagues.map { ($0.id, $0.name) })
        picker("Season", $model.season, model.seasons.map { ($0, $0) })
        picker("Stage", $model.stage, model.stages.map { ($0.key, $0.label) })
        picker("Team", $model.team, model.teamChoices.map { ($0.abbr, $0.name) })
      }
    }
    .listStyle(.sidebar)
    .onChange(of: model.league) { model.stage = nil; model.team = nil }
  }

  private func picker(_ title: String, _ selection: Binding<String?>, _ options: [(String, String)]) -> some View {
    Picker(title, selection: selection) {
      Text("All").tag(String?.none)
      ForEach(options, id: \.0) { Text($0.1).tag(String?.some($0.0)) }
    }
  }
}

struct GameGrid: View {
  var model: AppModel

  var body: some View {
    let sections = model.sections
    ScrollView {
      if sections.isEmpty {
        ContentUnavailableView(model.refreshing ? "Loading the schedule…" : "No games here",
                               systemImage: "sportscourt",
                               description: Text(model.refreshing ? "This takes a few seconds the first time." : "Try other filters, or refresh the schedule."))
          .padding(.top, 120)
      } else {
        LazyVStack(alignment: .leading, spacing: 24, pinnedViews: .sectionHeaders) {
          ForEach(sections) { section in
            Section {
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)], spacing: 16) {
                ForEach(section.games) { GameCard(model: model, game: $0) }
              }
            } header: {
              Text(section.title).font(.title3.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).background(.bar)
            }
          }
        }
        .padding(20)
      }
    }
    .navigationTitle("Courtside")
    .navigationSubtitle("\(model.shownCount) games")
  }
}
