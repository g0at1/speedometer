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
                        .tint(.red)
                        .frame(height: 6)
                }

                MetricCard(title: "RAM") {
                    HStack {
                        Image(systemName: "memorychip")
                        Text("\(mon.memoryUsage, specifier: "%.1f")%")
                            .bold()
                    }
                    ProgressView(value: mon.memoryUsage, total: 100)
                        .tint(.blue)
                        .frame(height: 6)
                }

                MetricCard(title: "Network") {
                    HStack(spacing: 12) {
                        Label("\(mon.netInKBps, specifier: "%.0f") KB/s", systemImage: "arrow.down.circle")
                        Label("\(mon.netOutKBps, specifier: "%.0f") KB/s", systemImage: "arrow.up.circle")
                    }
                    .font(.subheadline)
                }

                MetricCard(title: "Storage") {
                    HStack {
                        Image(systemName: "internaldrive.fill")
                        Text("\(mon.diskUsage, specifier: "%.1f")%")
                            .bold()
                    }
                    ProgressView(value: mon.diskUsage, total: 100)
                        .tint(.green)
                        .frame(height: 6)
                    Text("\(mon.diskFreeGB, specifier: "%.1f") GB available of \(mon.diskTotalGB, specifier: "%.2f") GB")
                        .font(.footnote)
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
