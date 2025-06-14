import Combine
import Darwin
import Foundation
import IOKit.ps

class SystemMonitor: ObservableObject {
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0

    @Published var netInKBps: Double = 0
    @Published var netOutKBps: Double = 0

    @Published var diskUsage: Double = 0  // %
    @Published var diskFreeGB: Double = 0  // GB
    @Published var diskTotalGB: Double = 0  // GB
    @Published var gpuUsage: Double = 0
    @Published var uptime: TimeInterval = 0
    @Published var batteryLevel: Double = 0  // 0.0–100.0
    @Published var timeToFullCharge: TimeInterval = 0
    @Published var batteryHealth: Double = 100

    private var timer: Timer?
    private var lastNetStats:
        (timestamp: TimeInterval, bytesIn: UInt64, bytesOut: UInt64)?

    init() {
    }
    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            DispatchQueue.global(qos: .utility).async {
                let cpu = self.getCPUUsage()
                let ram = self.getMemoryUsage()
                let (inB, outB) = self.getNetworkUsage()
                let (free, total) = self.getDiskSpace()
                let gpu = self.getGPUUsage()
                let up = self.getSystemUptimeSinceBoot()
                let (level, timeToFull, health) = self.getBatteryInfo()

                DispatchQueue.main.async {
                    self.cpuUsage = cpu
                    self.memoryUsage = ram
                    self.netInKBps = Double(inB) / 1024.0
                    self.netOutKBps = Double(outB) / 1024.0
                    self.diskFreeGB = free
                    self.diskTotalGB = total
                    self.diskUsage =
                        total > 0 ? ((total - free) / total) * 100.0 : 0
                    self.gpuUsage = gpu
                    self.uptime = up
                    self.batteryLevel = level
                    self.timeToFullCharge = timeToFull
                    self.batteryHealth = health
                }
            }
        }

        if let t = timer {
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
        }
    }

    func stopMonitoring() {
        timer?.invalidate()
    }

    // MARK: – CPU

    private func getCPUUsage() -> Double {
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        var cpuInfo = host_cpu_load_info()
        let hostPort = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(
                    hostPort,
                    HOST_CPU_LOAD_INFO,
                    $0,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(cpuInfo.cpu_ticks.0)
        let sys = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)
        let total = user + sys + nice + idle
        let used = total - idle
        return (used / total) * 100.0
    }

    // MARK: – PAMIĘĆ

    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = UInt32(
            MemoryLayout<vm_statistics64_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(
                    mach_host_self(),
                    HOST_VM_INFO64,
                    $0,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let usedPages = Double(
            stats.active_count + stats.wire_count + stats.compressor_page_count
        )
        let freePages = Double(stats.free_count + stats.inactive_count)
        let usedBytes = usedPages * pageSize
        let totalBytes = (usedPages + freePages) * pageSize
        return (usedBytes / totalBytes) * 100.0
    }

    // MARK: – SIEĆ (KB/s)

    private func getNetworkUsage() -> (bytesIn: UInt64, bytesOut: UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else {
            return (0, 0)
        }
        defer { freeifaddrs(addrs) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var ptr = first

        repeat {
            let flags = Int32(ptr.pointee.ifa_flags)
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_LINK) && (flags & IFF_LOOPBACK) == 0 {
                let data = ptr.pointee.ifa_data
                    .assumingMemoryBound(to: if_data.self)
                    .pointee
                totalIn += UInt64(data.ifi_ibytes)
                totalOut += UInt64(data.ifi_obytes)
            }
            if let next = ptr.pointee.ifa_next {
                ptr = next
            } else {
                break
            }
        } while true

        let now = Date().timeIntervalSince1970
        defer { lastNetStats = (now, totalIn, totalOut) }

        guard let last = lastNetStats else {
            return (0, 0)
        }
        let dt = now - last.timestamp
        guard dt > 0 else { return (0, 0) }

        let deltaIn = totalIn - last.bytesIn
        let deltaOut = totalOut - last.bytesOut
        return (
            UInt64(Double(deltaIn) / dt),
            UInt64(Double(deltaOut) / dt)
        )
    }

    // MARK: – DYSK

    private func getDiskSpace() -> (freeGB: Double, totalGB: Double) {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return (0, 0) }
        let blockSize = Double(stat.f_bsize)
        let freeBytes = Double(stat.f_bavail) * blockSize
        let totalBytes = Double(stat.f_blocks) * blockSize
        return (
            freeBytes / 1_000_000_000,
            totalBytes / 1_000_000_000
        )
    }

    private func getGPUUsage() -> Double {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        task.arguments = ["-l", "-w0", "-c", "IOAccelerator"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
        } catch {
            print("Failed to run process: \(error)")
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return 0 }

        let regexPattern = #"PercentBusy\s*=\s*(\d+)"#
        if let regex = try? NSRegularExpression(pattern: regexPattern),
            let match = regex.firstMatch(
                in: output,
                range: NSRange(output.startIndex..., in: output)
            ),
            let range = Range(match.range(at: 1), in: output),
            let number = Double(output[range])
        {
            return number
        }
        return 0
    }

    private func getSystemUptimeSinceBoot() -> TimeInterval {
        var boottime = timeval()
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var size = MemoryLayout<timeval>.stride

        let result = sysctl(&mib, UInt32(mib.count), &boottime, &size, nil, 0)
        guard result == 0 else {
            return ProcessInfo.processInfo.systemUptime
        }

        let bootDate = Date(
            timeIntervalSince1970: TimeInterval(boottime.tv_sec)
                + TimeInterval(boottime.tv_usec) / 1_000_000
        )

        return Date().timeIntervalSince(bootDate)
    }

    private func getBatteryHealth() -> Double {
        let matchingNames = ["AppleSmartBattery", "AppleSmartBatteryManager"]
        var service: io_service_t = 0
        for name in matchingNames {
            service = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching(name)
            )
            if service != 0 { break }
        }
        guard service != 0 else { return 100 }
        defer { IOObjectRelease(service) }

        let rawKeys = ["AppleRawMaxCapacity", "MaxCapacity"]
        let maxCap =
            rawKeys.compactMap { key in
                IORegistryEntryCreateCFProperty(
                    service,
                    key as CFString,
                    kCFAllocatorDefault,
                    0
                )?
                .takeRetainedValue() as? NSNumber
            }.first?.doubleValue ?? 0

        let designCap =
            (IORegistryEntryCreateCFProperty(
                service,
                "DesignCapacity" as CFString,
                kCFAllocatorDefault,
                0
            )?
            .takeRetainedValue() as? NSNumber)?
            .doubleValue ?? 0

        return designCap > 0
            ? (maxCap / designCap) * 100.0
            : 100.0
    }

    private func getBatteryInfo() -> (
        level: Double, timeToFull: TimeInterval, health: Double
    ) {
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef],
            let ps = list.first,
            let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any]
        else {
            return (0, 0, 100)
        }

        let currentCapInt = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let maxCapInt = desc[kIOPSMaxCapacityKey as String] as? Int ?? 1

        let currentCap = Double(currentCapInt)
        let maxCap = Double(maxCapInt)

        let level = (currentCap / maxCap) * 100.0

        let minutesToFull =
            desc[kIOPSTimeToFullChargeKey as String] as? Int ?? -1
        let secondsToFull = minutesToFull > 0 ? Double(minutesToFull) * 60.0 : 0

        let health = self.getBatteryHealth()

        return (level, secondsToFull, health)
    }
}
