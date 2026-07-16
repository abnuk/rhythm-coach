import Foundation

/// Subdivision density of the click grid.
public enum Subdivision: String, Codable, Sendable, CaseIterable, Identifiable {
    case quarter
    case eighth
    case sixteenth
    case eighthTriplet
    case sixteenthTriplet

    public var id: String { rawValue }

    /// Grid slots per beat.
    public var slotsPerBeat: Int {
        switch self {
        case .quarter: 1
        case .eighth: 2
        case .sixteenth: 4
        case .eighthTriplet: 3
        case .sixteenthTriplet: 6
        }
    }

    public var displayName: String {
        switch self {
        case .quarter: "1/4"
        case .eighth: "1/8"
        case .sixteenth: "1/16"
        case .eighthTriplet: "1/8T"
        case .sixteenthTriplet: "1/16T"
        }
    }
}

/// Which grid slots produce an audible click. The analysis grid (scoring)
/// always uses every slot — this only thins out what you HEAR, e.g. hear
/// quarter-note clicks while your 16th-note playing is tracked per slot.
public enum ClickDensity: String, Codable, Sendable, CaseIterable, Identifiable {
    case everySlot
    case beatsOnly
    case downbeatsOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .everySlot: "Every subdivision"
        case .beatsOnly: "Beats only"
        case .downbeatsOnly: "Bar starts only"
        }
    }
}

/// Gap-click: `barsOn` audible bars followed by `barsOff` silent bars,
/// repeating. Silent bars are still part of the grid and still scored.
public struct GapPattern: Codable, Sendable, Equatable {
    public var barsOn: Int
    public var barsOff: Int

    public init(barsOn: Int, barsOff: Int) {
        self.barsOn = max(1, barsOn)
        self.barsOff = max(1, barsOff)
    }
}

/// Full description of a practice grid.
public struct ClickGridSpec: Codable, Sendable, Equatable {
    public var bpm: Double
    public var subdivision: Subdivision
    public var beatsPerBar: Int
    public var accentDownbeat: Bool
    /// What you hear; scoring always tracks every slot of `subdivision`.
    public var clickDensity: ClickDensity
    public var gapPattern: GapPattern?
    public var countInBars: Int
    /// Practice target: intentionally play this many ms behind (+) or
    /// ahead (-) of the grid; scoring is relative to the shifted reference.
    public var targetOffsetMs: Double
    /// When true, empty slots count as "missed". Turn off when playing
    /// patterns with rests — only actual hits are then scored.
    public var expectEverySlot: Bool

    public init(
        bpm: Double = 90,
        subdivision: Subdivision = .eighth,
        beatsPerBar: Int = 4,
        accentDownbeat: Bool = true,
        clickDensity: ClickDensity = .everySlot,
        gapPattern: GapPattern? = nil,
        countInBars: Int = 1,
        targetOffsetMs: Double = 0,
        expectEverySlot: Bool = true
    ) {
        self.bpm = bpm
        self.subdivision = subdivision
        self.beatsPerBar = beatsPerBar
        self.accentDownbeat = accentDownbeat
        self.clickDensity = clickDensity
        self.gapPattern = gapPattern
        self.countInBars = countInBars
        self.targetOffsetMs = targetOffsetMs
        self.expectEverySlot = expectEverySlot
    }
}

/// Deterministic slot math on the shared sample timeline (t=0 is the first
/// count-in slot). Pure value type; safe to use from the realtime thread.
public struct ClickGrid: Sendable {
    public let spec: ClickGridSpec
    public let sampleRate: Double
    public let samplesPerBeat: Double
    public let samplesPerSlot: Double
    public let slotsPerBar: Int
    public let countInSlots: Int

    public init(spec: ClickGridSpec, sampleRate: Double) {
        self.spec = spec
        self.sampleRate = sampleRate
        self.samplesPerBeat = sampleRate * 60.0 / spec.bpm
        self.samplesPerSlot = samplesPerBeat / Double(spec.subdivision.slotsPerBeat)
        self.slotsPerBar = spec.beatsPerBar * spec.subdivision.slotsPerBeat
        self.countInSlots = spec.countInBars * slotsPerBar
    }

    public func sampleTime(ofSlot index: Int) -> Double {
        Double(index) * samplesPerSlot
    }

    public func nearestSlot(to sampleTime: Double) -> Int {
        Int((sampleTime / samplesPerSlot).rounded())
    }

    public func isCountIn(slot index: Int) -> Bool {
        index < countInSlots
    }

    public func bar(ofSlot index: Int) -> Int {
        Int(floor(Double(index) / Double(slotsPerBar)))
    }

    /// Accent level of a slot: bar downbeat > beat > subdivision.
    public enum SlotKind: Sendable {
        case downbeat
        case beat
        case subdivision
    }

    public func kind(ofSlot index: Int) -> SlotKind {
        let inBar = ((index % slotsPerBar) + slotsPerBar) % slotsPerBar
        if inBar == 0 { return .downbeat }
        return inBar % spec.subdivision.slotsPerBeat == 0 ? .beat : .subdivision
    }

    /// Whether the click for this slot is audible: the click density thins
    /// slots by kind everywhere; the gap pattern silences whole bars after
    /// the count-in (the count-in itself is never gapped).
    public func isAudible(slot index: Int) -> Bool {
        switch spec.clickDensity {
        case .everySlot:
            break
        case .beatsOnly:
            if case .subdivision = kind(ofSlot: index) { return false }
        case .downbeatsOnly:
            guard case .downbeat = kind(ofSlot: index) else { return false }
        }
        if index < countInSlots { return true }
        guard let gap = spec.gapPattern else { return true }
        let barAfterCountIn = bar(ofSlot: index) - spec.countInBars
        let cycle = gap.barsOn + gap.barsOff
        return barAfterCountIn % cycle < gap.barsOn
    }
}
