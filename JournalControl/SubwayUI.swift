// Visual atoms of the Option B subway design (palette, line bullet, ring, train row, alert badge, line chip), shared by
// the home-screen widget, the Live Activity (JournalControl/SubwayWidget.swift) and the Superapp's Subway screen
// (JournalControl/SubwayScreenView.swift). Compiled into the extension, the Superapp and SubwayTests, so everything here
// must stay iOS 15 compatible (the Superapp's deployment target); anything needing Button(intent:) lives in the widget file.

import SwiftUI

/// Deep link that opens the Superapp's Subway screen (handled by Modules/Subway/SubwayModule.m).
let subwayScreenURL = URL(string: "overland://subway")!

// MTA line colours (official palette).
func bulletColor(_ line: String) -> Color {
    switch line.first {
    case "1", "2", "3": return Color(red: 0.93, green: 0.21, blue: 0.18)
    case "4", "5", "6": return Color(red: 0.0, green: 0.58, blue: 0.24)
    case "7": return Color(red: 0.73, green: 0.2, blue: 0.68)
    case "A", "C", "E": return Color(red: 0.0, green: 0.22, blue: 0.65)
    case "B", "D", "F", "M": return Color(red: 1.0, green: 0.39, blue: 0.1)
    case "G": return Color(red: 0.42, green: 0.75, blue: 0.27)
    case "J", "Z": return Color(red: 0.6, green: 0.4, blue: 0.2)
    case "L": return Color(red: 0.65, green: 0.66, blue: 0.68)
    case "N", "Q", "R", "W": return Color(red: 0.99, green: 0.8, blue: 0.04)
    default: return Color(red: 0.5, green: 0.51, blue: 0.52)
    }
}

/// Colour tokens from the design mockup (light + dark), picked explicitly from the colour scheme so renders are deterministic.
struct SubwayPalette {
    let dark: Bool
    var bg: Color { dark ? Color(red: 0.11, green: 0.11, blue: 0.118) : .white }
    var fg: Color { dark ? .white : .black }
    var mut: Color { dark ? Color(red: 0.596, green: 0.596, blue: 0.624) : Color(red: 0.431, green: 0.431, blue: 0.451) }
    var chip: Color { dark ? Color(red: 0.92, green: 0.92, blue: 0.96).opacity(0.14) : Color(red: 0.235, green: 0.235, blue: 0.263).opacity(0.10) }
    func color(_ u: SubwayUrgency) -> Color {
        switch u {
        case .now: return dark ? Color(red: 1, green: 0.271, blue: 0.227) : Color(red: 1, green: 0.231, blue: 0.188)
        case .soon: return dark ? Color(red: 1, green: 0.624, blue: 0.039) : Color(red: 0.902, green: 0.525, blue: 0)
        case .ok: return dark ? Color(red: 0.188, green: 0.82, blue: 0.345) : Color(red: 0.122, green: 0.659, blue: 0.29)
        }
    }
    /// Ring track tint.
    func tint(_ u: SubwayUrgency) -> Color {
        switch u {
        case .now: return dark ? Color(red: 1, green: 0.271, blue: 0.227).opacity(0.22) : Color(red: 1, green: 0.231, blue: 0.188).opacity(0.14)
        case .soon: return dark ? Color(red: 1, green: 0.624, blue: 0.039).opacity(0.22) : Color(red: 1, green: 0.584, blue: 0).opacity(0.18)
        case .ok: return dark ? Color(red: 0.188, green: 0.82, blue: 0.345).opacity(0.20) : Color(red: 0.204, green: 0.78, blue: 0.349).opacity(0.17)
        }
    }
    func alertColor(_ t: SubwayAlertTone) -> Color {
        switch t {
        case .severe: return color(.now)
        case .warning: return color(.soon)
        case .ended: return mut
        }
    }
    /// Background of the most urgent row.
    func rowHighlight(_ u: SubwayUrgency) -> Color { color(u).opacity(dark ? 0.10 : 0.07) }
}

struct Bullet: View {
    let line: String
    var size: CGFloat = 24
    var body: some View {
        Text(line)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(["N", "Q", "R", "W"].contains(line) ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(bulletColor(line), in: Circle())
    }
}

enum SubwayDensity {
    case small, medium, live

    var rowHeight: CGFloat { self == .small ? 36 : self == .medium ? 38 : 34 }
    var rowGap: CGFloat { self == .live ? 4 : 0 }
    var maxRows: Int { 3 }
    var bullet: CGFloat { self == .small ? 20 : 24 }
    var ring: CGFloat { self == .small ? 26 : self == .medium ? 34 : 30 }
    var ringLine: CGFloat { self == .small ? 3 : 3.5 }
    var ringFont: CGFloat { self == .small ? 11 : self == .medium ? 14 : 13 }
    var destFont: CGFloat { self == .small ? 12 : 13 }
    var subFont: CGFloat { self == .small ? 10 : 12 }
    var subGap: CGFloat { self == .small ? 2 : 8 }
    var hPad: CGFloat { self == .live ? 16 : 14 }
    var vPad: CGFloat { self == .live ? 12 : 14 }
    var titleFont: CGFloat { self == .small ? 14 : 15 }
    var rowSpacing: CGFloat { self == .small ? 6 : 9 }
}

/// Small warning badge overlapping the top-right of a line bullet.
struct AlertBadge: View {
    let tone: SubwayAlertTone
    let size: CGFloat
    let palette: SubwayPalette
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: size * 0.52, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(palette.alertColor(tone), in: Circle())
            .overlay(Circle().stroke(palette.bg, lineWidth: 1.5))
    }
}

struct Glyph: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Image(systemName: name).font(.system(size: size, weight: .semibold)).fixedSize()
    }
}

/// Ring: the number is minutes until the train; the arc is the share of the walk time still available.
struct Ring: View {
    let timing: SubwayTiming
    let density: SubwayDensity
    let palette: SubwayPalette
    var body: some View {
        let u = timing.urgency
        ZStack {
            Circle().stroke(palette.tint(u), lineWidth: density.ringLine)
            Circle().trim(from: 0, to: timing.fraction)
                .stroke(palette.color(u), style: StrokeStyle(lineWidth: density.ringLine, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Text("\(timing.minsToTrain)")
                .font(.system(size: density.ringFont, weight: .bold)).monospacedDigit()
                .foregroundStyle(palette.color(u))
        }
        .frame(width: density.ring - density.ringLine, height: density.ring - density.ringLine)
        .frame(width: density.ring, height: density.ring)
    }
}

struct TrainRow: View {
    let row: SubwayState.Row
    let walkSec: Double
    let now: Double
    let density: SubwayDensity
    let palette: SubwayPalette
    let highlighted: Bool
    var alert: SubwayState.Alert?

    var body: some View {
        let t = row.timing(walkSec: walkSec, now: now)
        let u = t.urgency
        let dest = density == .small ? subwayShortDest(row.dest) : row.dest
        HStack(spacing: density.rowSpacing) {
            Bullet(line: row.line, size: density.bullet)
                .overlay(alignment: .topTrailing) {
                    if let alert {
                        AlertBadge(tone: alert.tone, size: density == .small ? 11 : 13, palette: palette)
                            .offset(x: 4, y: -4)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("\u{2192}").fontWeight(.medium).foregroundStyle(palette.mut)
                    Text(dest).fontWeight(.semibold).foregroundStyle(palette.fg).lineLimit(1).minimumScaleFactor(0.85)
                }
                .font(.system(size: density.destFont))
                HStack(spacing: density.subGap) {
                    HStack(spacing: 3) {
                        Glyph(name: "tram.fill", size: density.subFont - 1).foregroundStyle(palette.mut)
                        Text(row.clock()).fontWeight(.semibold).foregroundStyle(palette.fg)
                    }
                    HStack(spacing: 3) {
                        Glyph(name: "figure.walk", size: density.subFont).foregroundStyle(palette.mut)
                        Text(row.leaveLabel(walkSec: walkSec, now: now)).fontWeight(.semibold).foregroundStyle(palette.color(u))
                    }
                }
                .font(.system(size: density.subFont)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Ring(timing: t, density: density, palette: palette)
        }
        .padding(.horizontal, highlighted ? 6 : 0)
        .frame(height: density.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10).fill(highlighted ? palette.rowHighlight(u) : .clear))
        .padding(.horizontal, highlighted ? -6 : 0)
    }
}

/// A line toggle: the coloured bullet when the line is shown, a muted ring when hidden, a spinner while a change is in
/// flight. Pure visual; the widget wraps it in Button(intent:) and the Subway screen in a Button.
struct LineChip: View {
    let line: String
    let hidden: Bool
    var pending = false
    var size: CGFloat = 24
    let palette: SubwayPalette
    var body: some View {
        ZStack {
            if hidden {
                Text(line).font(.system(size: size * 0.55, weight: .bold)).foregroundStyle(palette.mut)
                    .frame(width: size, height: size)
                    .background(palette.chip, in: Circle())
            } else {
                Bullet(line: line, size: size)
            }
            if pending {
                // The user's change is not confirmed yet: cover the bullet with a spinner so a tap visibly registered.
                Circle().fill(palette.bg.opacity(0.55)).frame(width: size, height: size)
                ProgressView().scaleEffect(size > 22 ? 0.8 : 0.6)
            }
        }
        .frame(width: size, height: size)
    }
}
