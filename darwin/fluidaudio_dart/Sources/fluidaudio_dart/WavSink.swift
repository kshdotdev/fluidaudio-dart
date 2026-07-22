import AVFoundation
import Foundation
import os

/// Streams the 16 kHz mono float32 capture pipeline into a WAV file
/// (16-bit PCM on disk; `AVAudioFile` converts from the float processing
/// format transparently).
///
/// Pure sink semantics: it never starts or stops the capture it is attached
/// to. Writes happen on the capture's serial dispatch context; [close] may
/// race a straggling write after the capture's queue is shut down, so the
/// file handle is lock-protected. Mid-write errors are swallowed (matching
/// the reference recorder) — a disk hiccup drops frames but never disturbs
/// the live fan-out. Closing finalizes the RIFF header; it is idempotent.
final class WavSink {
  private let file: OSAllocatedUnfairLock<AVAudioFile?>

  init(path: String) throws {
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ]
    let handle = try AVAudioFile(
      forWriting: URL(fileURLWithPath: path), settings: settings)
    file = OSAllocatedUnfairLock(initialState: handle)
  }

  /// Appends [samples] (16 kHz mono float32). A no-op once closed.
  func write(_ samples: [Float]) {
    guard let pcm = AudioBridge.pcmBuffer(from: samples) else { return }
    file.withLock { handle in
      guard let handle else { return }
      try? handle.write(from: pcm)
    }
  }

  /// Releases the file, which patches the RIFF/data chunk lengths.
  func close() {
    file.withLock { $0 = nil }
  }
}
