// Entry point of the Quotes app's widget extension (com.oliverullman.quotes.widget).
// The widget itself is in QuotesWidget.swift.
import WidgetKit
import SwiftUI

@main
struct QuotesWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuotesWidget()
    }
}
