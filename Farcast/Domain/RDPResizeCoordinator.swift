import CoreGraphics
import Foundation

struct RDPResizeRequest: Equatable {
    let width: Int
    let height: Int
    let scale: Int
    var size: CGSize { CGSize(width: width, height: height) }

    init?(width: Int, height: Int, scale: Int) {
        guard (200...8192).contains(width), width % 2 == 0, (200...8192).contains(height),
            (100...500).contains(scale)
        else { return nil }
        self.width = width
        self.height = height
        self.scale = scale
    }

    init?(points: CGSize, backing: CGSize, backingScale: Double, retina: Bool) {
        let source = retina ? backing : points
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0,
            backingScale.isFinite, (1...5).contains(backingScale)
        else { return nil }
        width = Int(min(8192, max(200, floor(source.width / 2) * 2)))
        height = Int(min(8192, max(200, floor(source.height))))
        scale = retina ? Int((backingScale * 100).rounded()) : 100
    }
}

/// Local tokens correlate channel submission, never a remote Display Control acknowledgment.
struct RDPResizeCoordinator {
    struct Submission: Equatable {
        let id: Int
        let request: RDPResizeRequest
    }
    enum Observation: Equatable {
        case availability(RDPResizeRequest)
        case geometry(Submission)
    }
    private(set) var desired: RDPResizeRequest?
    private(set) var pending: Submission?
    private(set) var available = false
    private(set) var observedSize: CGSize?
    private var handled: RDPResizeRequest?
    private var lastScale = 100
    private var sequence = 0

    var isSatisfied: Bool {
        guard let desired else { return false }
        return pending == nil && desired.size == observedSize && desired.scale == lastScale
    }

    /// Only unfinished work gets a deadline. Merely having a desired size is
    /// insufficient: the initial desktop may already match it before caps arrive.
    var observation: Observation? {
        if let pending { return .geometry(pending) }
        guard !available, let desired, desired != handled,
            desired.size != observedSize || desired.scale != lastScale
        else { return nil }
        return .availability(desired)
    }

    mutating func initialScale(_ scale: Int) { lastScale = scale }
    mutating func request(_ value: RDPResizeRequest) -> Submission? {
        if desired != value { handled = nil }
        desired = value
        return next()
    }
    mutating func availability(_ value: Bool) -> Submission? {
        if available != value {
            pending = nil
            handled = nil
        }
        available = value
        return next()
    }
    mutating func observe(_ size: CGSize) -> Submission? {
        observedSize = size
        if let pending, pending.request.size == size {
            handled = pending.request
            self.pending = nil
        }
        return next()
    }
    mutating func result(id: Int, submitted: Bool) -> Submission? {
        guard let pending, pending.id == id else { return nil }
        if submitted { lastScale = pending.request.scale }
        // Graphics dimensions cannot confirm a DPI-only change. Handle it once.
        if !submitted || pending.request.size == observedSize {
            handled = pending.request
            self.pending = nil
        }
        return next()
    }
    mutating func expire() -> Submission? {
        if let pending { handled = pending.request } else if !available { handled = desired }
        pending = nil
        return next()
    }
    mutating func cancel() {
        desired = nil
        pending = nil
        handled = nil
    }
    private mutating func next() -> Submission? {
        guard available, pending == nil, let desired, desired != handled else { return nil }
        guard desired.size != observedSize || desired.scale != lastScale else { return nil }
        sequence += 1
        let submission = Submission(id: sequence, request: desired)
        pending = submission
        return submission
    }
}
