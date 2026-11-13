// State file decoding and list/row selection for the Lists widget. No SwiftUI or WidgetKit here, so
// the logic stays plain and readable on its own. The page (ListsApp/web) owns the schema and writes
// state.json through ListsApp/ListsStateStore.m; this file only reads the keys the widget shows.
//
// Decoding is tolerant by design, because the page adds keys over time: unknown keys are ignored
// (Codable does that by itself), and `deleted` / `categoryId` / `note` may be missing. A value of the
// WRONG TYPE (say a string `order`) still throws, and the widget shows that error rather than
// guessing: it means the page and widget disagree about the schema.
import Foundation

struct ListsState: Decodable {
    struct ListInfo: Decodable {
        let id: String
        let name: String
        let order: Double
        let deleted: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            order = try c.decode(Double.self, forKey: .order)
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        }
        private enum CodingKeys: String, CodingKey { case id, name, order, deleted }
    }

    struct Category: Decodable {
        let id: String
        let color: String
        let order: Double
        let deleted: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            color = try c.decode(String.self, forKey: .color)
            order = try c.decode(Double.self, forKey: .order)
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        }
        private enum CodingKeys: String, CodingKey { case id, color, order, deleted }
    }

    struct Item: Decodable {
        let id: String
        let listId: String
        let name: String
        let categoryId: String?
        let checked: Bool
        let createdAt: Double
        let deleted: Bool

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            listId = try c.decode(String.self, forKey: .listId)
            name = try c.decode(String.self, forKey: .name)
            categoryId = try c.decodeIfPresent(String.self, forKey: .categoryId)
            checked = try c.decode(Bool.self, forKey: .checked)
            createdAt = try c.decode(Double.self, forKey: .createdAt)
            deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        }
        private enum CodingKeys: String, CodingKey { case id, listId, name, categoryId, checked, createdAt, deleted }
    }

    let widgetListId: String?
    let lists: [ListInfo]
    let categories: [Category]
    let items: [Item]
}

/// What the widget draws for one list: its name, the unchecked count, and the unchecked rows in order.
struct ListsSnapshot {
    struct Row {
        let id: String
        let name: String
        /// "#RRGGBB" of the item's category, nil when the category is unknown (neutral dot).
        let colorHex: String?
    }

    /// nil when the state has no usable list at all (every list deleted, or none created yet).
    let listId: String?
    let listName: String?
    let uncheckedCount: Int
    let rows: [Row]
}

enum ListsWidgetModel {
    /// The list shown: `widgetListId` when it names a live list, else the first live list by `order`.
    static func chosenList(in state: ListsState) -> ListsState.ListInfo? {
        let live = state.lists.filter { !$0.deleted }
        if let wanted = state.widgetListId, let match = live.first(where: { $0.id == wanted }) {
            return match
        }
        return live.sorted { $0.order < $1.order }.first
    }

    /// Unchecked, non-deleted items of the chosen list ordered by category `order` then `createdAt`.
    /// An item whose category is missing or unknown sorts after every known category and gets no color.
    static func snapshot(from state: ListsState) -> ListsSnapshot {
        guard let list = chosenList(in: state) else {
            return ListsSnapshot(listId: nil, listName: nil, uncheckedCount: 0, rows: [])
        }
        var categoryById: [String: ListsState.Category] = [:]
        for category in state.categories where !category.deleted { categoryById[category.id] = category }

        let open = state.items.filter { $0.listId == list.id && !$0.deleted && !$0.checked }
        let ordered = open.sorted { a, b in
            let ao = a.categoryId.flatMap { categoryById[$0]?.order } ?? Double.infinity
            let bo = b.categoryId.flatMap { categoryById[$0]?.order } ?? Double.infinity
            if ao != bo { return ao < bo }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id // total order, so the widget never reshuffles between reloads
        }
        let rows = ordered.map { item in
            ListsSnapshot.Row(id: item.id, name: item.name, colorHex: item.categoryId.flatMap { categoryById[$0]?.color })
        }
        return ListsSnapshot(listId: list.id, listName: list.name, uncheckedCount: rows.count, rows: rows)
    }
}
