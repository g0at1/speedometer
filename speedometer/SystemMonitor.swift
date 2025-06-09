import Foundation
import Combine
import Darwin

class SystemMonitor: ObservableObject {
    // istniejące metryki
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0
    
    // sieć (KB/s)
    @Published var netInKBps: Double = 0
    @Published var netOutKBps: Double = 0
    
    // dysk
    @Published var diskUsage: Double = 0         // %
    @Published var diskFreeGB: Double = 0        // GB
    @Published var diskTotalGB: Double = 0       // GB

    private var timer: Timer?
    private var lastNetStats: (timestamp: TimeInterval, bytesIn: UInt64, bytesOut: UInt64)?

    init() {
    }
    deinit {
        stopMonitoring()
    }

    func startMonitoring() {
        // 1) create a bare Timer (don’t use scheduledTimer)
        timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // gather metrics off the main thread
            DispatchQueue.global(qos: .utility).async {
                let cpu    = self.getCPUUsage()
                let ram    = self.getMemoryUsage()
                let (inB, outB) = self.getNetworkUsage()
                let (free, total) = self.getDiskSpace()

                // publish back on the main thread
                DispatchQueue.main.async {
                    self.cpuUsage    = cpu
                    self.memoryUsage = ram
                    self.netInKBps   = Double(inB)  / 1024.0
                    self.netOutKBps  = Double(outB) / 1024.0
                    self.diskFreeGB  = free
                    self.diskTotalGB = total
                    self.diskUsage   = total > 0 ? ((total - free) / total) * 100.0 : 0
                }
            }
        }

        // 2) add it to the main run loop in common modes
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
            MemoryLayout<host_cpu_load_info_data_t>.size /
            MemoryLayout<integer_t>.size
        )
        var cpuInfo = host_cpu_load_info()
        let hostPort = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &cpuInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(hostPort,
                                HOST_CPU_LOAD_INFO,
                                $0,
                                &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user   = Double(cpuInfo.cpu_ticks.0)
        let sys    = Double(cpuInfo.cpu_ticks.1)
        let idle   = Double(cpuInfo.cpu_ticks.2)
        let nice   = Double(cpuInfo.cpu_ticks.3)
        let total  = user + sys + nice + idle
        let used   = total - idle
        return (used / total) * 100.0
    }

    // MARK: – PAMIĘĆ

    private func getMemoryUsage() -> Double {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size /
                           MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(),
                                 HOST_VM_INFO64,
                                 $0,
                                 &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize   = Double(vm_kernel_page_size)
        let usedPages  = Double(stats.active_count +
                                stats.wire_count +
                                stats.compressor_page_count)
        let freePages  = Double(stats.free_count + stats.inactive_count)
        let usedBytes  = usedPages * pageSize
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
            let flags      = Int32(ptr.pointee.ifa_flags)
            let family     = ptr.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_LINK) && (flags & IFF_LOOPBACK) == 0 {
                let data = ptr.pointee.ifa_data
                    .assumingMemoryBound(to: if_data.self)
                    .pointee
                totalIn  += UInt64(data.ifi_ibytes)
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

        let deltaIn  = totalIn  - last.bytesIn
        let deltaOut = totalOut - last.bytesOut
        return ( UInt64(Double(deltaIn)  / dt),
                 UInt64(Double(deltaOut) / dt) )
    }

    // MARK: – DYSK

    private func getDiskSpace() -> (freeGB: Double, totalGB: Double) {
        var stat = statfs()
        guard statfs("/", &stat) == 0 else { return (0, 0) }
        let blockSize  = Double(stat.f_bsize)
        let freeBytes  = Double(stat.f_bavail)  * blockSize
        let totalBytes = Double(stat.f_blocks)   * blockSize
        return (freeBytes  / 1_000_000_000,
                totalBytes / 1_000_000_000)
    }
}
