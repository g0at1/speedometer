import SwiftUI

struct MetricCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            content
        }
        .padding()
        .background(.thinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
    }
}

struct ContentView: View {
    @StateObject private var mon = SystemMonitor()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                MetricCard(title: "CPU") {
                    HStack {
                        Image(systemName: "cpu.fill")
                        Text("\(mon.cpuUsage, specifier: "%.1f")%")
                            .bold()
                    }
                    ProgressView(value: mon.cpuUsage, total: 100)
                        .tint(color(for: mon.cpuUsage))
                        .frame(height: 6)
                }

                MetricCard(title: "GPU") {
                    HStack {
                        Image(systemName: "cpu.fill")
                        Text("\(mon.gpuUsage, specifier: "%.0f")%")
                            .bold()
                    }
                    ProgressView(value: mon.gpuUsage, total: 100)
                        .tint(color(for: mon.gpuUsage))
                        .frame(height: 6)
                }

                MetricCard(title: "RAM") {
                    HStack {
                        Image(systemName: "memorychip")
                        Text("\(mon.memoryUsage, specifier: "%.1f")%")
                            .bold()
                    }
                    ProgressView(value: mon.memoryUsage, total: 100)
                        .tint(color(for: mon.memoryUsage))
                        .frame(height: 6)
                }

                MetricCard(title: "Network") {
                    HStack(spacing: 12) {
                        Label("\(mon.netInKBps, specifier: "%.0f") KB/s", systemImage: "arrow.down.circle")
                        Label("\(mon.netOutKBps, specifier: "%.0f") KB/s", systemImage: "arrow.up.circle")
                    }
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                MetricCard(title: "Storage") {
                    HStack {
                        Image(systemName: "internaldrive.fill")
                        Text("\(mon.diskUsage, specifier: "%.1f")%")
                            .bold()
                    }
                    ProgressView(value: mon.diskUsage, total: 100)
                        .tint(color(for: mon.diskUsage))
                        .frame(height: 6)
                    Text("\(mon.diskFreeGB, specifier: "%.1f") GB available of \(mon.diskTotalGB, specifier: "%.2f") GB")
                        .font(.footnote)
                }
                MetricCard(title: "Uptime") {
                    HStack {
                        Image(systemName: "clock.fill")
                        Text(format(uptime: mon.uptime))
                            .bold()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .frame(width: 280)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { mon.startMonitoring() }
        .onDisappear { mon.stopMonitoring() }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

private func color(for percentage: Double) -> Color {
    switch percentage {
    case 0..<50:
        return .green
    case 50..<80:
        return .orange
    default:
        return .red
    }
}

private func format(uptime: TimeInterval) -> String {
    let totalSeconds = Int(uptime)
    let days    = totalSeconds / 86_400
    let hours   = (totalSeconds % 86_400) / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    if days > 0 {
        return "\(days)d \(hours)h \(minutes)m"
    } else {
        return "\(hours)h \(minutes)m"
    }
}
