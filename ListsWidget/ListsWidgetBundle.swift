// Entry point of the Lists app's widget extension (com.oliverullman.lists.widget).
// The widget itself is in ListsWidget.swift.
import WidgetKit
import SwiftUI

@main
struct ListsWidgetBundle: WidgetBundle {
    var body: some Widget {
        ListsWidget()
    }
}
