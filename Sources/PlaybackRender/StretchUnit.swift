/// The stretch's platform edge: a time-stretch that keeps pitch, over interleaved Float32. It reads
/// silence past what was `append`ed, so a caller renders only while enough input is queued, or to flush.
protocol StretchUnit: AnyObject {
    /// Input frames per output frame; each render pulls exactly this many per frame it makes.
    var rate: Double { get set }
    /// Input frames not yet pulled.
    var queuedFrames: Int { get }
    /// What comes out lags what was pulled by `window` input frames plus `window` output frames.
    var window: Int { get }
    func append(_ samples: [Float])
    func render(_ frames: Int) -> [Float]
}
