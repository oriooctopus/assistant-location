// Home Screen widget for the Lists app: the unchecked items of one list, colored by category.
// Display only. It reads state.json from the App Group container the app writes (see
// ListsApp/ListsStateStore.m); the app calls WidgetCenter.reloadAllTimelines after every save, so the
// timeline is a single entry with policy .never and no polling. No network here, ever.
import WidgetKit
import SwiftUI

// Must equal the group in ListsWidget.entitlements, Lists.entitlements and ListsStateStore.m.
private let listsAppGroup = "group.com.oliverullman.lists"

struct ListsEntry: TimelineEntry {
    enum Content {
        /// No state.json yet (the app was never opened): just the app name.
        case noState
        case list(ListsSnapshot)
        /// The file exists but could not be read or decoded; shown instead of a blank tile.
        case failed(String)
    }
    let date: Date
    let content: Content
}

struct ListsTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ListsEntry {
        ListsEntry(date: Date(), content: .list(ListsSnapshot(
            listId: nil, listName: "Groceries", uncheckedCount: 3,
            rows: [.init(id: "1", name: "Milk", colorHex: "#4C9AFF"),
                   .init(id: "2", name: "Apples", colorHex: "#36B37E"),
                   .init(id: "3", name: "Bread", colorHex: "#FFAB00")])))
    }

    func getSnapshot(in context: Context, completion: @escaping (ListsEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ListsEntry>) -> Void) {
        completion(Timeline(entries: [load()], policy: .never))
    }

    private func load() -> ListsEntry {
        let now = Date()
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: listsAppGroup) else {
            return ListsEntry(date: now, content: .failed("no App Group container for \(listsAppGroup)"))
        }
        let url = container.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ListsEntry(date: now, content: .noState)
        }
        do {
            let data = try Data(contentsOf: url)
            let state = try JSONDecoder().decode(ListsState.self, from: data)
            return ListsEntry(date: now, content: .list(ListsWidgetModel.snapshot(from: state)))
        } catch {
            return ListsEntry(date: now, content: .failed("state.json: \(error)"))
        }
    }
}

private extension Color {
    /// "#RRGGBB" to a color; nil for anything else (the dot then falls back to the neutral color).
    init?(hex: String) {
        guard hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

struct ListsWidgetView: View {
    var entry: ListsEntry

    // Row metrics are fixed (not Dynamic Type scaled) so the "how many rows fit" arithmetic below holds.
    private let rowHeight: CGFloat = 19
    private let headerHeight: CGFloat = 24

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(url)
            .containerBackground(.background, for: .widget)
    }

    // Opens the Lists app on this list (ListsAppDelegate handles lists://list/<id>).
    private var url: URL? {
        if case .list(let snap) = entry.content, let id = snap.listId,
           let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return URL(string: "lists://list/\(encoded)")
        }
        return URL(string: "lists://")
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .noState:
            Text("Lists").font(.system(size: 15, weight: .semibold))
        case .failed(let message):
            Text(message).font(.caption2).foregroundStyle(.red).lineLimit(6)
        case .list(let snap):
            listBody(snap)
        }
    }

    private func listBody(_ snap: ListsSnapshot) -> some View {
        GeometryReader { geo in
            // Rows that fit under the header. When the list is longer than that, the last slot is
            // given to the "+N" line, so N counts every row not drawn.
            let capacity = max(0, Int((geo.size.height - headerHeight) / rowHeight))
            let overflow = snap.rows.count > capacity
            let shown = overflow ? max(0, capacity - 1) : snap.rows.count
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(snap.listName ?? "Lists")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(snap.uncheckedCount)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(height: headerHeight, alignment: .top)
                ForEach(Array(snap.rows.prefix(shown)), id: \.id) { row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(row.colorHex.flatMap { Color(hex: $0) } ?? Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(row.name).font(.system(size: 13)).lineLimit(1)
                    }
                    .frame(height: rowHeight, alignment: .leading)
                }
                if overflow {
                    Text("+\(snap.rows.count - shown)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(height: rowHeight, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct ListsWidget: Widget {
    let kind: String = "com.oliverullman.lists.listswidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ListsTimelineProvider()) { entry in
            ListsWidgetView(entry: entry)
        }
        .configurationDisplayName("List")
        .description("The unchecked items of one list.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
