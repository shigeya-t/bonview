import BonDriver
import ChannelScan
import Foundation
import TSCore

// bdpcat — command-line BonDriver_Proxy / BonDriver_Tunnel client.
//
//   bdpcat -c BonDriver_Proxy.ini --list
//   bdpcat --tunnel -a 192.168.0.10 -d PT3-T --list          (BonDriverTunnel, port 1193)
//   bdpcat --tunnel -c BonDriver_PT3-T.ini --list
//   bdpcat -a 192.168.0.10 -d BonDriver_PT3-T.dll --space 0 --channel 3 -t 10 -o out.ts
//   bdpcat ... -o - | ffplay -
//   bdpcat -c BonDriver_Proxy.ini --scan [--space S]           (channel scan)
//   bdpcat -c BonDriver_Proxy.ini --epg [--space S]            (scan, then read every channel's EIT schedule)

let usage = """
usage: bdpcat [--tunnel] [-c conf] [-a address] [-p port] -d bondriver [--lock N] [--no-b25]
              (--list | --scan [--space S] | --epg [--space S] | --space S --channel C [-t seconds] [-o file|-] [--info])
"""

/// The open connection: released before every exit (a top-level `defer` does not run on `exit`).
nonisolated(unsafe) var connection: BonDriver?

func finish(_ code: Int32) -> Never {
    connection?.release()
    exit(code)
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    finish(1)
}

// `bdpcat ... -o - | head` must end quietly when the reader goes away, not die of SIGPIPE.
signal(SIGPIPE, SIG_IGN)

var args = Array(CommandLine.arguments.dropFirst())
var config = ProxyConfig()
var tunnel = TunnelConfig()
var useTunnel = false
var portSet = false
var configPath: String?
var haveDriver = false
var list = false, info = false, scan = false, epg = false
var space: UInt32?, channel: UInt32?
var seconds: Double = 0
var output: String?
/// Options given on the command line win over the configuration file.
var overrides: [(inout ProxyConfig, inout TunnelConfig) -> Void] = []

func next() -> String {
    guard !args.isEmpty else { fail(usage) }
    return args.removeFirst()
}

while !args.isEmpty {
    switch args.removeFirst() {
    case "--tunnel": useTunnel = true
    case "-c", "--config": configPath = next()
    case "-a", "--address": let a = next(); overrides.append { $0.address = a; $1.address = a }
    case "-p", "--port":
        guard let p = UInt16(next()), p != 0 else { fail(usage) }
        overrides.append { $0.port = p; $1.port = p }
        portSet = true
    case "-d", "--bondriver": let d = next(); overrides.append { $0.bonDriver = d; $1.origin = d }; haveDriver = true
    case "--lock": let n = UInt8(next()) ?? 0; overrides.append { c, _ in c.channelLock = n }
    case "--no-b25": overrides.append { c, _ in c.requestB25 = false }
    case "--list": list = true
    case "--scan": scan = true
    case "--epg": epg = true; scan = true
    case "--info": info = true
    case "--space": space = UInt32(next())
    case "--channel": channel = UInt32(next())
    case "-t": seconds = Double(next()) ?? 0
    case "-o": output = next()
    case "-h", "--help": print(usage); exit(0)
    default: fail(usage)
    }
}
if let path = configPath {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS) ?? ""
    do {
        if useTunnel || TunnelConfig.looksLikeTunnelConfig(text) {
            useTunnel = true
            tunnel = try TunnelConfig.parse(text, fileName: (path as NSString).lastPathComponent)
        } else {
            config = try ProxyConfig.parse(text)
        }
        haveDriver = true
    } catch { fail("\(path): \(error)") }
}
if useTunnel && !portSet && configPath == nil { tunnel.port = 1193 }
for apply in overrides { apply(&config, &tunnel) }
guard haveDriver else { fail(usage) }

let client: BonDriver
do {
    client = useTunnel ? try TunnelClient.connect(config: tunnel) : try ProxyClient.connect(config: config)
    connection = client
    try client.openTuner()
} catch {
    fail("\(error)")
}

if list {
    for s in client.enumerateChannels() {
        print("[\(s.index)] \(s.name)")
        for c in s.channels { print("    \(c.index): \(c.name)") }
    }
    print("devices: \(client.activeDeviceNum)/\(client.totalDeviceNum)")
    finish(0)
}

if scan {
    let scanner = ChannelScanner()
    client.tsHandler = { scanner.feed($0) }
    let spaces = client.enumerateChannels().filter { space == nil || $0.index == space }
    let err = FileHandle.standardError
    let found = scanner.scan(client, spaces: spaces) { ev in
        switch ev {
        case .started(let ch, let i, let total): err.write("\r[\(i + 1)/\(total)] \(ch.name)        ".data(using: .utf8)!)
        case .found, .empty: break
        }
    }
    err.write("\n".data(using: .utf8)!)
    for c in found {
        print(String(format: "%@ (%d/%d)  TSID 0x%04X  ONID %@", c.channelName, c.space, c.channel, c.transportStreamID,
                     c.originalNetworkID.map { String(format: "0x%04X", $0) } ?? "-"))
        for s in c.services {
            let num = c.threeDigitNumber(for: s).map { String(format: "%03d", $0) } ?? "---"
            let dup = c.duplicateNameServiceIDs.contains(s.serviceID) ? "  (sub-channel)" : ""
            print(String(format: "    %@  SID %5d  type 0x%02X%@  %@%@", num, s.serviceID, s.serviceType,
                         s.isOneSeg ? " 1seg" : "", s.displayName, dup))
        }
    }
    print("\(found.count) channel(s) found")
    guard epg else { finish(0) }

    let grabber = EPGGrabber()
    client.tsHandler = { grabber.feed($0) }
    var store = EPGStore()
    do {
        try grabber.grab(client, channels: found) { ev in
            switch ev {
            case .started(let ch, let i, let total): err.write("\r[\(i + 1)/\(total)] EPG \(ch.channelName)        ".data(using: .utf8)!)
            case .updates(let u): store.merge(u)
            case .skipped, .locked, .finished: break
            }
        }
    } catch { fail("\(error)") }
    err.write("\n".data(using: .utf8)!)
    let f = DateFormatter()
    f.dateFormat = "MM/dd HH:mm"
    f.timeZone = TimeZone(identifier: "Asia/Tokyo")
    for c in found {
        for s in c.services where s.isViewable {
            guard let key = store.key(originalNetworkID: c.originalNetworkID, transportStreamID: c.transportStreamID, serviceID: s.serviceID) else { continue }
            let events = store.events(for: key, from: .distantPast, to: .distantFuture)
            print("\(s.displayName) (SID \(s.serviceID)): \(events.count) events")
            for ev in events {
                print("    \(f.string(from: ev.start!)) \(Int(ev.duration! / 60))分  \(ev.title)")
            }
        }
    }
    finish(0)
}

guard let space, let channel else { fail(usage) }

var out: FileHandle?
if let output {
    if output == "-" {
        out = .standardOutput
    } else {
        FileManager.default.createFile(atPath: output, contents: nil)
        out = FileHandle(forWritingAtPath: output) ?? { fail("cannot open \(output)") }()
    }
}

let demux = TSDemuxer()
let demuxQueue = DispatchQueue(label: "demux")
let lock = NSLock()
var total = 0
/// Set from the receive thread: a broken pipe / write error, or the connection failing.
var stopReason: String?
client.tsHandler = { data in
    lock.lock(); total += data.count; let stopped = stopReason != nil; lock.unlock()
    if stopped { return }
    if let out {
        do { try out.write(contentsOf: data) } catch {
            lock.lock(); stopReason = "output: \(error.localizedDescription)"; lock.unlock()
            return
        }
    }
    if info { demuxQueue.async { demux.feed(data) } }
}
// Called on the receive thread: just flag it, the main loop releases and exits.
client.errorHandler = { e in lock.lock(); stopReason = "\(e)"; lock.unlock() }

switch try? client.setChannel(space: space, channel: channel) {
case .tuned?: break
case .locked?: fail("channel is locked by another client")
case nil: fail("SetChannel(\(space), \(channel)) failed")
}

let log = FileHandle.standardError
let start = Date()
while seconds <= 0 || Date().timeIntervalSince(start) < seconds {
    sleep(1)
    lock.lock(); let bytes = total; let reason = stopReason; lock.unlock()
    if let reason { log.write("\n".data(using: .utf8)!); fail(reason) }
    let elapsed = Date().timeIntervalSince(start)
    log.write(String(format: "\r%6.1fs  %8.2f MB  %.2f Mbps  signal %.2f dB ",
                     elapsed, Double(bytes) / 1e6, Double(bytes) * 8 / elapsed / 1e6, client.signalLevel).data(using: .utf8)!)
}
log.write("\n".data(using: .utf8)!)

if info {
    demuxQueue.sync {
        let st = demux.stats
        print("TSID: \(demux.transportStreamID.map { String(format: "0x%04X", $0) } ?? "?")  packets: \(st.packets)  CC errors: \(st.continuityErrors)  scrambled: \(st.scrambledPackets)")
        for s in demux.services {
            let streams = s.streams.map { String(format: "%@/0x%04X", $0.codecName, $0.pid) }.joined(separator: ", ")
            print(String(format: "  SID %5d  %@  %@", s.serviceID, s.displayName, streams))
        }
        if let ev = demux.presentEvent { print("  現在: \(ev.title)") }
    }
}
finish(0)
