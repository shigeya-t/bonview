import Foundation

public struct ServiceInfo: Identifiable, Equatable, Sendable {
    public var serviceID: UInt16
    public var name: String
    public var serviceType: UInt8
    public var pmtPID: UInt16
    public var streams: [ElementaryStreamInfo]
    public var scrambled: Bool

    public var id: UInt16 { serviceID }
    /// ISDB-T partial reception (ワンセグ) PMTs live at 0x1FC8–0x1FCF.
    public var isOneSeg: Bool { (0x1FC8...0x1FCF).contains(pmtPID) }
    public var hasVideo: Bool { streams.contains { $0.isVideo } }
    public var displayName: String { name.isEmpty ? String(format: "サービス %d", serviceID) : name }
}

public struct StreamSelection: Equatable, Sendable {
    public var serviceID: UInt16
    public var video: ElementaryStreamInfo?
    public var audio: ElementaryStreamInfo?
    public var audioStreams: [ElementaryStreamInfo]
}

public struct DemuxStats: Sendable {
    public var packets = 0
    public var bytes = 0
    public var errorPackets = 0
    public var continuityErrors = 0
    public var scrambledPackets = 0
    /// Scrambled packets on the selected service's video/audio PIDs.
    public var scrambledSelectedPackets = 0
    public var syncLoss = 0
}

/// TS demultiplexer: tracks PAT/PMT/SDT/EIT/TOT and outputs the PES of the selected service.
///
/// Not thread-safe; drive it from one queue.
public final class TSDemuxer {
    public enum Track: Sendable { case video, audio }

    public var onServicesChanged: (([ServiceInfo]) -> Void)?
    public var onSelectionChanged: ((StreamSelection?) -> Void)?
    public var onPES: ((Track, ElementaryStreamInfo, PESPacket) -> Void)?
    /// Present / following events of the selected service.
    public var onEventChanged: ((EventInfo?, EventInfo?) -> Void)?
    public var onTime: ((Date) -> Void)?

    /// Service to select. nil → first TV service (excluding one-seg).
    public var preferredServiceID: UInt16? { didSet { if oldValue != preferredServiceID { reselect() } } }
    /// Index into the selected service's audio streams (主音声 / 副音声 …).
    public var audioIndex = 0 { didSet { if oldValue != audioIndex { reselect() } } }

    public private(set) var stats = DemuxStats()
    public private(set) var services: [ServiceInfo] = []
    public private(set) var selection: StreamSelection?
    public private(set) var transportStreamID: UInt16?
    public private(set) var originalNetworkID: UInt16?
    public private(set) var presentEvent: EventInfo?
    public private(set) var followingEvent: EventInfo?

    private var splitter = TSPacketSplitter()
    private var sections: [UInt16: SectionAssembler] = [:]
    private var pes: [UInt16: PESAssembler] = [:]
    private var lastCC: [UInt16: UInt8] = [:]
    private var pat: PAT?
    private var pmtPIDs: [UInt16: UInt16] = [:] // PID → program number
    private var pmts: [UInt16: PMT] = [:]       // program number → PMT
    private var sdtServices: [UInt16: SDT.Service] = [:]

    private static let sdtPID: UInt16 = 0x0011
    private static let eitPIDs: Set<UInt16> = [0x0012, 0x0026, 0x0027]
    private static let totPID: UInt16 = 0x0014

    public init() {}

    /// Forget everything (call after a channel change).
    public func reset() {
        splitter.reset()
        sections.removeAll()
        pes.removeAll()
        lastCC.removeAll()
        pat = nil
        pmtPIDs.removeAll()
        pmts.removeAll()
        sdtServices.removeAll()
        services = []
        transportStreamID = nil
        originalNetworkID = nil
        presentEvent = nil
        followingEvent = nil
        stats = DemuxStats()
        if selection != nil {
            selection = nil
            onSelectionChanged?(nil)
        }
        onServicesChanged?([])
        onEventChanged?(nil, nil)
    }

    public func feed(_ data: Data) {
        stats.bytes += data.count
        splitter.split(data) { handle($0) }
        stats.syncLoss = splitter.syncLossCount
    }

    // MARK: - Packet routing

    private func handle(_ p: TSPacket) {
        stats.packets += 1
        // Until the first PAT the tuner may still be locking / the server may still be sending
        // the previous channel; don't count that as errors.
        let counting = pat != nil
        if p.transportError { if counting { stats.errorPackets += 1 }; return }
        let pid = p.pid
        if pid == 0x1FFF { return }

        if p.hasPayload {
            let cc = p.continuityCounter
            if let last = lastCC[pid], !p.discontinuityIndicator {
                if last == cc { return } // duplicate packet
                if (last + 1) & 0x0F != cc {
                    if counting { stats.continuityErrors += 1 }
                    sections[pid]?.reset()
                    pes[pid]?.reset()
                }
            }
            lastCC[pid] = cc
        }
        guard let payload = p.payload else { return }

        if p.scramblingControl != 0 {
            if counting {
                stats.scrambledPackets += 1
                if pes[pid] != nil { stats.scrambledSelectedPackets += 1 }
            }
            return
        }

        if pid == 0x0000 || pid == Self.sdtPID || pid == Self.totPID || Self.eitPIDs.contains(pid) || pmtPIDs[pid] != nil {
            var asm = sections[pid] ?? SectionAssembler()
            asm.push(payload, unitStart: p.payloadUnitStart) { section(pid, $0) }
            sections[pid] = asm
            return
        }

        if var asm = pes[pid], let sel = selection {
            let track: Track
            let info: ElementaryStreamInfo
            if let v = sel.video, v.pid == pid { track = .video; info = v }
            else if let a = sel.audio, a.pid == pid { track = .audio; info = a }
            else { return }
            asm.push(payload, unitStart: p.payloadUnitStart) { onPES?(track, info, $0) }
            pes[pid] = asm
        }
    }

    // MARK: - Tables

    private func section(_ pid: UInt16, _ s: [UInt8]) {
        switch s[0] {
        case 0x00 where pid == 0:
            guard let newPAT = PAT(s), newPAT != pat else { return }
            if let old = pat, old.transportStreamID != newPAT.transportStreamID {
                sdtServices.removeAll()
                presentEvent = nil
                followingEvent = nil
            }
            pat = newPAT
            transportStreamID = newPAT.transportStreamID
            let valid = Set(newPAT.programs.map(\.programNumber))
            pmts = pmts.filter { valid.contains($0.key) }
            pmtPIDs = Dictionary(newPAT.programs.map { ($0.pmtPID, $0.programNumber) }, uniquingKeysWith: { a, _ in a })
            rebuildServices()
        case 0x02:
            guard let program = pmtPIDs[pid], let pmt = PMT(s), pmt.programNumber == program else { return }
            if pmts[program] == pmt { return }
            pmts[program] = pmt
            rebuildServices()
        case 0x42 where pid == Self.sdtPID:
            guard let sdt = SDT(s), transportStreamID == nil || sdt.transportStreamID == transportStreamID else { return }
            originalNetworkID = sdt.originalNetworkID
            var changed = false
            for svc in sdt.services {
                let old = sdtServices[svc.serviceID]
                if old?.name != svc.name || old?.serviceType != svc.serviceType { changed = true }
                sdtServices[svc.serviceID] = svc
            }
            if changed { rebuildServices() }
        case 0x4E where Self.eitPIDs.contains(pid):
            guard let eit = EIT(s), eit.serviceID == selection?.serviceID else { return }
            let ev = eit.events.first
            if eit.sectionNumber == 0 {
                if ev != presentEvent { presentEvent = ev; onEventChanged?(presentEvent, followingEvent) }
            } else if eit.sectionNumber == 1 {
                if ev != followingEvent { followingEvent = ev; onEventChanged?(presentEvent, followingEvent) }
            }
        case 0x70 where pid == Self.totPID, 0x73 where pid == Self.totPID:
            if let t = TOT.time(s) { onTime?(t) }
        default:
            break
        }
    }

    private func rebuildServices() {
        guard let pat else { return }
        let list = pat.programs.map { prog -> ServiceInfo in
            let pmt = pmts[prog.programNumber]
            let sdt = sdtServices[prog.programNumber]
            return ServiceInfo(serviceID: prog.programNumber, name: sdt?.name ?? "", serviceType: sdt?.serviceType ?? 0,
                               pmtPID: prog.pmtPID, streams: pmt?.streams ?? [], scrambled: pmt?.ecmPID != nil)
        }
        if list != services {
            services = list
            onServicesChanged?(list)
        }
        reselect()
    }

    private func reselect() {
        let ready = services.filter { pmts[$0.serviceID] != nil }
        let svc = ready.first { $0.serviceID == preferredServiceID }
            ?? ready.first { $0.hasVideo && !$0.isOneSeg && ($0.serviceType == 0 || $0.serviceType == 0x01 || $0.serviceType == 0xAD) }
            ?? ready.first { $0.hasVideo }
            ?? ready.first
        var new: StreamSelection? = nil
        if let svc {
            let audios = svc.streams.filter(\.isAudio)
            new = StreamSelection(serviceID: svc.serviceID,
                                  video: svc.streams.first(where: \.isVideo),
                                  audio: audios.indices.contains(audioIndex) ? audios[audioIndex] : audios.first,
                                  audioStreams: audios)
        }
        guard new != selection else { return }
        let serviceChanged = new?.serviceID != selection?.serviceID
        selection = new
        pes.removeAll()
        if let v = new?.video { pes[v.pid] = PESAssembler() }
        if let a = new?.audio { pes[a.pid] = PESAssembler() }
        if serviceChanged {
            presentEvent = nil
            followingEvent = nil
            onEventChanged?(nil, nil)
        }
        onSelectionChanged?(new)
    }
}
