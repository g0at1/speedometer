import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

struct SystemStats: Equatable {
    var cpuUsage: Double = 0
    var memoryUsage: Double = 0

    var netInKBps: Double = 0
    var netOutKBps: Double = 0
    var netInHistory: [Double] = []  // KB/s
    var netOutHistory: [Double] = []  // KB/s

    var diskUsage: Double = 0  // %
    var diskFreeGB: Double = 0  // GB
    var diskTotalGB: Double = 0  // GB
    var gpuUsage: Double = 0
    var uptime: TimeInterval = 0
    var batteryLevel: Double = 0  // 0.0–100.0
    var timeToFullCharge: TimeInterval = 0
    var batteryHealth: Double = 100
    var hasBattery = false
    var isCharging = false
    var isPluggedIn = false
}

/// Publishes a fresh `SystemStats` once per second while monitoring.
///
/// All sampling happens on a private serial queue, so samples never overlap
/// and the sampler's state needs no locking. The UI gets one update per tick.
final class SystemMonitor: ObservableObject {
    static let historyLength = 60

    @Published private(set) var stats = SystemStats()

    private let queue = DispatchQueue(
        label: "com.michalL.speedometer.sampler", qos: .utility)
    private let sampler = Sampler(historyLength: historyLength)
    private var timer: DispatchSourceTimer?

    deinit {
        timer?.cancel()
    }

    func startMonitoring() {
        guard timer == nil else { return }
        let sampler = sampler
        queue.async { sampler.reset() }

        let t = DispatchSource.makeTimerSource(queue: queue)
        // First tick shortly after priming so CPU/network deltas are meaningful.
        t.schedule(
            deadline: .now() + .milliseconds(250),
            repeating: .seconds(1),
            leeway: .milliseconds(250)
        )
        t.setEventHandler { [weak self] in
            let next = sampler.sample()
            DispatchQueue.main.async {
                guard let self, self.timer != nil, self.stats != next else {
                    return
                }
                self.stats = next
            }
        }
        timer = t
        t.resume()
    }

    func stopMonitoring() {
        timer?.cancel()
        timer = nil
    }
}

/// Reads system metrics. Only ever used from `SystemMonitor`'s serial queue.
final class Sampler {
    private let historyLength: Int
    private let hostPort = mach_host_self()
    private let bootDate = Sampler.readBootDate()

    private var stats = SystemStats()
    private var tick = 0
    private var lastCPUTicks: (used: UInt64, total: UInt64)?
    private var lastNet: (time: UInt64, bytesIn: UInt64, bytesOut: UInt64)?
    private var gpuServices: [io_service_t] = []

    // Slow-changing values are refreshed less often than every tick.
    private let diskEvery = 10
    private let batteryEvery = 5
    private let batteryHealthEvery = 300

    init(historyLength: Int) {
        self.historyLength = historyLength
    }

    deinit {
        gpuServices.forEach { IOObjectRelease($0) }
        mach_port_deallocate(mach_task_self_, hostPort)
    }

    /// Primes the delta-based counters and clears history, so a restart
    /// after the window was closed doesn't average over the closed period.
    func reset() {
        tick = 0
        stats.netInHistory = []
        stats.netOutHistory = []
        lastCPUTicks = nil
        lastNet = nil
        _ = readCPUUsage()
        _ = readNetworkRates()
    }

    func sample() -> SystemStats {
        stats.cpuUsage = readCPUUsage() ?? stats.cpuUsage
        stats.memoryUsage = readMemoryUsage() ?? stats.memoryUsage
        stats.gpuUsage = readGPUUsage() ?? stats.gpuUsage
        stats.uptime = Date().timeIntervalSince(bootDate)

        let (inKB, outKB) = readNetworkRates() ?? (0, 0)
        stats.netInKBps = inKB
        stats.netOutKBps = outKB
        stats.netInHistory = appending(inKB, to: stats.netInHistory)
        stats.netOutHistory = appending(outKB, to: stats.netOutHistory)

        if tick % diskEvery == 0, let (free, total) = readDiskSpace() {
            stats.diskFreeGB = free
            stats.diskTotalGB = total
            stats.diskUsage = total > 0 ? (total - free) / total * 100 : 0
        }
        if tick % batteryEvery == 0 {
            readBattery(includeHealth: tick % batteryHealthEvery == 0)
        }

        tick += 1
        return stats
    }

    private func appending(_ value: Double, to history: [Double]) -> [Double] {
        var history = history
        history.append(value)
        if history.count > historyLength {
            history.removeFirst(history.count - historyLength)
        }
        return history
    }

    // MARK: – CPU

    private func readCPUUsage() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        defer { lastCPUTicks = (used, total) }

        // Usage over the last interval, not the average since boot.
        guard let last = lastCPUTicks, total > last.total, used >= last.used
        else { return nil }
        return Double(used - last.used) / Double(total - last.total) * 100
    }

    // MARK: – Memory

    private func readMemoryUsage() -> Double? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let usedPages = Double(
            stats.active_count + stats.wire_count + stats.compressor_page_count
        )
        let freePages = Double(stats.free_count + stats.inactive_count)
        let totalPages = usedPages + freePages
        return totalPages > 0 ? usedPages / totalPages * 100 : nil
    }

    // MARK: – Network (KB/s)

    /// Uses 64-bit interface counters; `getifaddrs`' `if_data` counters are
    /// 32-bit and wrap every 4 GB.
    private func readNetworkRates() -> (inKB: Double, outKB: Double)? {
        guard let (bytesIn, bytesOut) = Sampler.readInterfaceBytes() else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        defer { lastNet = (now, bytesIn, bytesOut) }

        guard let last = lastNet, now > last.time else { return nil }
        let dt = Double(now - last.time) / 1_000_000_000
        // Counters drop when an interface disappears (e.g. VPN disconnect).
        let deltaIn = bytesIn >= last.bytesIn ? bytesIn - last.bytesIn : 0
        let deltaOut = bytesOut >= last.bytesOut ? bytesOut - last.bytesOut : 0
        return (Double(deltaIn) / dt / 1024, Double(deltaOut) / dt / 1024)
    }

    private static func readInterfaceBytes() -> (UInt64, UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0
        else { return nil }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(
                    fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                    offset + MemoryLayout<if_msghdr2>.size <= length
                {
                    let info = raw.loadUnaligned(
                        fromByteOffset: offset, as: if_msghdr2.self)
                    if info.ifm_flags & IFF_LOOPBACK == 0 {
                        totalIn += info.ifm_data.ifi_ibytes
                        totalOut += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (totalIn, totalOut)
    }

    // MARK: – Disk

    private func readDiskSpace() -> (freeGB: Double, totalGB: Double)? {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return nil }
        let blockSize = Double(stat.f_bsize)
        return (
            Double(stat.f_bavail) * blockSize / 1_000_000_000,
            Double(stat.f_blocks) * blockSize / 1_000_000_000
        )
    }

    // MARK: – GPU

    /// Reads the accelerator's utilization straight from the IORegistry.
    private func readGPUUsage() -> Double? {
        if gpuServices.isEmpty {
            gpuServices = Sampler.matchServices("IOAccelerator")
        }
        let values = gpuServices.compactMap { service -> Double? in
            guard
                let stats = IORegistryEntryCreateCFProperty(
                    service, "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? [String: Any],
                let value = stats["Device Utilization %"] as? NSNumber
                    ?? stats["GPU Activity(%)"] as? NSNumber
            else { return nil }
            return value.doubleValue
        }
        if values.isEmpty {
            // GPU went away (e.g. eGPU unplugged); rematch next tick.
            gpuServices.forEach { IOObjectRelease($0) }
            gpuServices = []
            return nil
        }
        return values.max()
    }

    private static func matchServices(_ className: String) -> [io_service_t] {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching(className), &iterator)
                == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var services: [io_service_t] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            services.append(service)
        }
        return services
    }

    // MARK: – Uptime

    private static func readBootDate() -> Date {
        var boottime = timeval()
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var size = MemoryLayout<timeval>.stride
        guard sysctl(&mib, u_int(mib.count), &boottime, &size, nil, 0) == 0
        else {
            return Date(
                timeIntervalSinceNow: -ProcessInfo.processInfo.systemUptime)
        }
        return Date(
            timeIntervalSince1970: TimeInterval(boottime.tv_sec)
                + TimeInterval(boottime.tv_usec) / 1_000_000
        )
    }

    // MARK: – Battery

    private func readBattery(includeHealth: Bool) {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef],
            let source = list.first,
            let desc = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
        else {
            stats.hasBattery = false
            stats.isPluggedIn = true
            return
        }

        let current = Double(desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0)
        let max = Double(desc[kIOPSMaxCapacityKey as String] as? Int ?? 0)
        let minutesToFull =
            desc[kIOPSTimeToFullChargeKey as String] as? Int ?? -1

        stats.hasBattery = true
        stats.batteryLevel = max > 0 ? current / max * 100 : 0
        stats.timeToFullCharge =
            minutesToFull > 0 ? Double(minutesToFull) * 60 : 0
        stats.isCharging = desc[kIOPSIsChargingKey as String] as? Bool ?? false
        stats.isPluggedIn =
            desc[kIOPSPowerSourceStateKey as String] as? String
            == kIOPSACPowerValue
        if includeHealth {
            stats.batteryHealth = readBatteryHealth() ?? stats.batteryHealth
        }
    }

    private func readBatteryHealth() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(
                service, key as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber)?.doubleValue
        }
        guard
            let maxCapacity = number("AppleRawMaxCapacity")
                ?? number("MaxCapacity"),
            let designCapacity = number("DesignCapacity"), designCapacity > 0
        else { return nil }
        return maxCapacity / designCapacity * 100
    }
}
