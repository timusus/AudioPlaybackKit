@_spi(Testing) import PlaybackRender

public extension Transport {
    /// A transport on the fake output's manual clock, with the pump and decode jobs run by hand
    /// (`ManualPumpTimer.fire()`, `ManualExecutor.runUntilIdle()`), so an app's test needs no SPI import.
    convenience init(
        output: FakeAudioOutput,
        timer: ManualPumpTimer,
        executor: ManualExecutor,
        onEvent: @escaping @Sendable (TransportEvent<Item>) -> Void
    ) {
        self.init(output: output as any AudioOutput, timer: timer as any PumpTimer, executor: executor as any SequencerExecutor, onEvent: onEvent)
    }
}
