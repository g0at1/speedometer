import AppKit
import SwiftUI

// MARK: – Building blocks

struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
    }
}

/// A 270° speedometer-style arc with an icon in the middle.
struct ArcGauge: View {
    let value: Double  // 0–100
    let tint: Color
    let systemImage: String

    private let sweep = 0.75

    var body: some View {
        let fraction = min(max(value / 100, 0), 1)
        ZStack {
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(
                    Color.primary.opacity(0.1),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
            Circle()
                .trim(from: 0, to: sweep * fraction)
                .stroke(
                    tint.gradient,
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .rotationEffect(.degrees(-135))
        }
        .rotationEffect(.degrees(135))
        .frame(width: 44, height: 44)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}

struct GaugeTile: View {
    let title: String
    let systemImage: String
    let value: Double
    let detail: String
    var tint: Color? = nil

    var body: some View {
        let tint = tint ?? usageColor(for: value)
        Card {
            HStack(spacing: 10) {
                ArcGauge(value: value, tint: tint, systemImage: systemImage)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(
                        value / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: value))
                    .animation(.smooth, value: value)
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
    }
}

struct Meter: View {
    let value: Double  // 0–100
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(6, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
        .animation(.smooth(duration: 0.5), value: value)
    }
}

/// Line chart that scrolls in from the right as samples arrive.
struct Sparkline: Shape {
    let values: [Double]
    let maxValue: Double
    let capacity: Int
    var filled = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, maxValue > 0 else { return path }
        let step = rect.width / CGFloat(capacity - 1)
        let points = values.enumerated().map { i, v in
            CGPoint(
                x: rect.maxX - CGFloat(values.count - 1 - i) * step,
                y: rect.maxY - CGFloat(min(v / maxValue, 1)) * rect.height
            )
        }
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        if filled {
            path.addLine(to: CGPoint(x: points.last!.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct RateLabel: View {
    let title: String
    let systemImage: String
    let kbps: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(formatRate(kbps))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: – Window

struct ContentView: View {
    @StateObject private var mon = SystemMonitor()

    private static let coreCount = ProcessInfo.processInfo.activeProcessorCount
    private static let memoryTotalGB =
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    private let columns = [
        GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 12) {
            header

            LazyVGrid(columns: columns, spacing: 8) {
                GaugeTile(
                    title: "CPU",
                    systemImage: "cpu",
                    value: mon.stats.cpuUsage,
                    detail: "\(Self.coreCount) cores"
                )
                GaugeTile(
                    title: "GPU",
                    systemImage: "square.stack.3d.up.fill",
                    value: mon.stats.gpuUsage,
                    detail: "Utilization"
                )
                GaugeTile(
                    title: "Memory",
                    systemImage: "memorychip",
                    value: mon.stats.memoryUsage,
                    detail: memoryDetail
                )
                GaugeTile(
                    title: "Storage",
                    systemImage: "internaldrive",
                    value: mon.stats.diskUsage,
                    detail: String(format: "%.0f GB free", mon.stats.diskFreeGB)
                )
            }

            network

            if mon.stats.hasBattery {
                battery
            }

            footer
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { mon.startMonitoring() }
        .onDisappear { mon.stopMonitoring() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .yellow, .orange],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )
            Text("Speedometer")
                .font(.headline)
            Spacer()
            Label(format(uptime: mon.stats.uptime), systemImage: "clock")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
                .help("Uptime since last boot")
        }
        .padding(.horizontal, 2)
    }

    private var network: some View {
        let peak = max(
            (mon.stats.netInHistory + mon.stats.netOutHistory).max() ?? 0,
            64  // keep idle noise flat
        )
        let capacity = SystemMonitor.historyLength
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    RateLabel(
                        title: "Download",
                        systemImage: "arrow.down.circle.fill",
                        kbps: mon.stats.netInKBps,
                        tint: .blue
                    )
                    RateLabel(
                        title: "Upload",
                        systemImage: "arrow.up.circle.fill",
                        kbps: mon.stats.netOutKBps,
                        tint: .purple
                    )
                }
                ZStack {
                    Sparkline(
                        values: mon.stats.netInHistory, maxValue: peak,
                        capacity: capacity, filled: true
                    )
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.3), .blue.opacity(0)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    Sparkline(
                        values: mon.stats.netInHistory, maxValue: peak,
                        capacity: capacity
                    )
                    .stroke(.blue, lineWidth: 1.5)
                    Sparkline(
                        values: mon.stats.netOutHistory, maxValue: peak,
                        capacity: capacity
                    )
                    .stroke(.purple, lineWidth: 1.5)
                }
                .frame(height: 34)
                .background(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 1)
                }
            }
        }
    }

    private var battery: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: batterySymbol)
                        .font(.system(size: 15))
                        .foregroundStyle(
                            mon.stats.isCharging
                                ? .green : batteryColor(for: mon.stats.batteryLevel)
                        )
                    Text("Battery")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(
                        mon.stats.batteryLevel / 100,
                        format: .percent.precision(.fractionLength(0))
                    )
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                }
                Meter(
                    value: mon.stats.batteryLevel,
                    tint: batteryColor(for: mon.stats.batteryLevel)
                )
                HStack {
                    Text(batteryStatus)
                    Spacer()
                    Text(
                        "Health \(mon.stats.batteryHealth / 100, format: .percent.precision(.fractionLength(0)))"
                    )
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(
                    URL(
                        fileURLWithPath:
                            "/System/Applications/Utilities/Activity Monitor.app"
                    )
                )
            } label: {
                Label("Activity Monitor", systemImage: "waveform.path.ecg")
            }
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private var memoryDetail: String {
        let usedGB = Self.memoryTotalGB * mon.stats.memoryUsage / 100
        return String(format: "%.1f of %.0f GB", usedGB, Self.memoryTotalGB)
    }

    private var batterySymbol: String {
        if mon.stats.isCharging { return "battery.100percent.bolt" }
        switch mon.stats.batteryLevel {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var batteryStatus: String {
        if mon.stats.isCharging {
            return mon.stats.timeToFullCharge > 0
                ? "Charging · \(formatDuration(mon.stats.timeToFullCharge)) to full"
                : "Charging"
        }
        return mon.stats.isPluggedIn ? "Plugged in" : "On battery"
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

// MARK: – Formatting

private func usageColor(for percentage: Double) -> Color {
    switch percentage {
    case 0..<50:
        return .green
    case 50..<80:
        return .orange
    default:
        return .red
    }
}

private func batteryColor(for percentage: Double) -> Color {
    switch percentage {
    case 0..<20:
        return .red
    case 20..<50:
        return .orange
    default:
        return .green
    }
}

private func formatRate(_ kbps: Double) -> String {
    switch kbps {
    case ..<1024:
        return String(format: "%.0f KB/s", kbps)
    case ..<(1024 * 1024):
        return String(format: "%.1f MB/s", kbps / 1024)
    default:
        return String(format: "%.2f GB/s", kbps / 1024 / 1024)
    }
}

private func format(uptime: TimeInterval) -> String {
    let totalSeconds = Int(uptime)
    let days = totalSeconds / 86_400
    let hours = (totalSeconds % 86_400) / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    if days > 0 {
        return "\(days)d \(hours)h \(minutes)m"
    } else {
        return "\(hours)h \(minutes)m"
    }
}

private func formatDuration(_ seconds: TimeInterval) -> String {
    let hrs = Int(seconds) / 3600
    let mins = (Int(seconds) % 3600) / 60
    return String(format: "%dh %dm", hrs, mins)
}
