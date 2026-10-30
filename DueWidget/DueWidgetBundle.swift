// Lock-screen entry points that open Due on the New Reminder sheet: a Control (Control Center / lock-screen corner) and
// an accessoryCircular widget. See DueComposeIntent.swift for why the Control goes through an intent.

import AppIntents
import SwiftUI
import WidgetKit

struct NewReminderControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.oliverullman.due.newremindercontrol") {
            ControlWidgetButton(action: DueNewReminderControlIntent()) {
                // Controls only draw symbols, so the logo is a custom symbol here and a template image in the widget.
                Label {
                    Text("New Reminder")
                } icon: {
                    Image("DueLogoSymbol")
                }
            }
        }
        .displayName("New Reminder")
    }
}

struct DueEntry: TimelineEntry {
    let date: Date
}

struct DueTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> DueEntry { DueEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (DueEntry) -> Void) { completion(DueEntry(date: Date())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<DueEntry>) -> Void) {
        completion(Timeline(entries: [DueEntry(date: Date())], policy: .never))
    }
}

struct NewReminderCircularView: View {
    var entry: DueEntry

    var body: some View {
        // widgetURL (not an intent) is the OS's standard deep-link path and supports custom schemes.
        ZStack {
            AccessoryWidgetBackground()
            Image("DueLogo")
                .resizable()
                .scaledToFit()
                .padding(9)
        }
        .widgetURL(URL(string: "dueclone://new")!)
        .widgetAccentable()
    }
}

struct NewReminderLockScreenWidget: Widget {
    let kind: String = "com.oliverullman.due.newremindercircle"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DueTimelineProvider()) { entry in
            NewReminderCircularView(entry: entry)
        }
        .configurationDisplayName("New Reminder")
        .description("Add a reminder from the Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

@main
struct DueWidgetBundle: WidgetBundle {
    var body: some Widget {
        NewReminderControl()
        NewReminderLockScreenWidget()
    }
}
