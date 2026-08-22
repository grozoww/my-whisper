import AVFoundation

/// Feeds exactly one buffer to an `AVAudioConverter`, then reports "no more data".
///
/// `AVAudioConverter.convert(to:error:withInputFrom:)` pulls input through a block it may call
/// more than once, and handing it the same buffer twice would duplicate audio. The obvious
/// implementation — a captured `var consumed = false` — is rejected under Swift 6, because the
/// block is typed `@Sendable` even though the converter in fact calls it synchronously on the
/// calling thread before returning.
///
/// This makes that guarantee explicit instead of arguing with the compiler about it. The
/// `@unchecked` is honest: safety rests on the synchronous-call contract above, not on a lock.
final class SingleBufferSource: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Returns the buffer on the first call and nil on every call after.
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

extension AVAudioConverter {
    /// Converts one input buffer into `output`, handling the feed-once dance.
    func convertOnce(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) throws {
        let source = SingleBufferSource(input)
        var error: NSError?
        convert(to: output, error: &error) { _, status in
            if let next = source.take() {
                status.pointee = .haveData
                return next
            }
            status.pointee = .noDataNow
            return nil
        }
        if let error { throw error }
    }
}
