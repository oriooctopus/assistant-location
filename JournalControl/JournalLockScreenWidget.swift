// Lock Screen accessory widgets (the widget-stack area below the clock — a
// different WidgetKit surface from the Control Center Controls in
// JournalControlBundle.swift/JournalControl). Let you start a voice or text
// journal entry without opening the app, via the same in-process
// URL-opening mechanism the Controls use (see
// JournalIntent.swift). Both intents are compiled into this extension
// target already, so no new target or pbxproj change is needed — these
// Widgets are simply added alongside the existing ControlWidgets in the same
// WidgetBundle (see @main JournalControlBundle below).
//
// Split into two .accessoryCircular widgets (Voice, Text) instead of one
// .accessoryRectangular row: on the Lock Screen, iOS renders ALL accessory
// widgets in a forced "vibrant" mode (monochrome, no custom background/
// blur/color — this is a hard platform restriction, not something this file
// can override). AccessoryWidgetBackground() is the one system-provided
// escape hatch: a filled circular backing shape designed for accessoryCircular
// /accessoryInline that reads with more visual weight than a bare icon, even
// under vibrant rendering. Two circular widgets also let iOS lay them out
// side by side in the widget-stack slot, similar to the corner Controls'
// two-button look.

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
        // backend endpoint exists to serve the day's journal prompts, this
        // can poll and refresh on a schedule instead of .never.
        completion(Timeline(entries: [JournalEntry(date: Date())], policy: .never))
    }
}

struct JournalVoiceCircularView: View {
    var entry: JournalEntry

    var body: some View {
        // Custom intent, not a bare OpenURLIntent — the direct form silently
        // did nothing on device (see JournalIntent.swift).
        Button(intent: StartJournalIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title2)
            }
        }
        .buttonStyle(.plain)
        .widgetAccentable()
    }
}

struct JournalTextCircularView: View {
    var entry: JournalEntry

    var body: some View {
        Button(intent: OpenTextJournalIntent()) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.title2)
            }
        }
        .buttonStyle(.plain)
        .widgetAccentable()
    }
}

struct JournalVoiceLockScreenWidget: Widget {
    let kind: String = "com.oliverullman.assistantlocation.journalvoicecircle"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { entry in
            JournalVoiceCircularView(entry: entry)
        }
        .configurationDisplayName("Voice Journal")
        .description("Start a voice journal entry from the Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

struct JournalTextLockScreenWidget: Widget {
    let kind: String = "com.oliverullman.assistantlocation.journaltextcircle"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: JournalTimelineProvider()) { entry in
            JournalTextCircularView(entry: entry)
        }
        .configurationDisplayName("Text Journal")
        .description("Start a text journal entry from the Lock Screen.")
        .supportedFamilies([.accessoryCircular])
    }
}
