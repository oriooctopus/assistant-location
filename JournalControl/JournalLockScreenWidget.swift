// Lock Screen accessory widget (the widget-stack area below the clock — a
// different WidgetKit surface from the Control Center Controls in
// JournalControlBundle.swift/JournalControl). Lets you start a voice or text
// journal entry without opening the app, via the same in-process
// openAppWhenRun AppIntent mechanism StartJournalIntent already uses (see
// JournalIntent.swift). Both intents are compiled into this extension
// target already, so no new target or pbxproj change is needed — this
// Widget is simply added alongside the existing ControlWidget in the same
// WidgetBundle (see @main JournalControlBundle below).
//
// .accessoryRectangular is roughly two lines of small text/controls, not a
// rich content surface — kept to the two buttons only.

import AppIntents
import SwiftUI
import WidgetKit

struct JournalEntry: TimelineEntry {
    let date: Date
}

struct JournalTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> JournalEntry {
        JournalEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (JournalEntry) -> Void) {
        completion(JournalEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<JournalEntry>) -> Void) {
        // Nothing to fetch yet — static content, never refreshes. Once a
        // backend endpoint exists to serve the day's journal prompts (see
        // JournalLockScreenView below), this can poll and refresh on a
        // schedule instead of .never.
        completion(Timeline(entries: [JournalEntry(date: Date())], policy: .never))
    }
}

struct JournalLockScreenView: View {
    var entry: JournalEntry

    var body: some View {
        HStack(spacing: 4) {
            Text("Journal")
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button(intent: StartJournalIntent()) {
                Image(systemName: "mic.fill")
                    .font(.title3)
            }
            Button(intent: OpenTextJournalIntent()) {
                Image(systemName: "square.and.pencil")
                    .font(.title3)
            }
            // Future: a status/count line ("3 questions today") would go
            // here once a backend endpoint serving daily journal prompts
            // exists — out of scope for now, not fabricating placeholder
            // content.
        }
        .widgetAccentable()
    }
}

struct JournalLockScreenWidget: Widget {
    let kind: String = "com.oliverullman.assistantlocation.journallockscreen"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { entry in
            JournalLockScreenView(entry: entry)
        }
        .configurationDisplayName("Journal")
        .description("Start a voice or text journal entry from the Lock Screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}
