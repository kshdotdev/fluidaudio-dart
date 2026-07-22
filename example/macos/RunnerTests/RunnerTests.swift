import AVFoundation
import Cocoa
import FlutterMacOS
import XCTest

@testable import fluidaudio_dart

class RunnerTests: XCTestCase {

  func testAudioBridgeRoundTrip() {
    let samples: [Float] = [0.0, -1.5, 3.25, 16000.0]
    let data = AudioBridge.typedData(from: samples)
    XCTAssertEqual(data.data.count, samples.count * MemoryLayout<Float>.size)
    XCTAssertEqual(AudioBridge.floats(from: data), samples)
  }

  func testAudioBridgeEmptyBuffer() {
    let data = AudioBridge.typedData(from: [])
    XCTAssertEqual(AudioBridge.floats(from: data), [])
  }

  func testSystemInfoReturnsSummary() {
    let api = SystemHostApiImpl(debugEvents: DebugEventsHandler())
    let resultExpectation = expectation(description: "systemInfo completes")
    api.systemInfo { result in
      switch result {
      case .success(let info):
        XCTAssertFalse(info.summary.isEmpty)
        XCTAssertFalse(info.isAppleSilicon && info.isIntelMac)
      case .failure(let error):
        XCTFail("systemInfo failed: \(error)")
      }
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 5)
  }

  /// The load-bearing invariant: streaming audio must reach each actor in
  /// strict enqueue order — concurrent feeding reorders the decode stream.
  func testSerialTaskQueuePreservesFifoOrder() {
    final class Box: @unchecked Sendable {
      let lock = NSLock()
      var values: [Int] = []
      func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
      }
    }

    let queue = SerialTaskQueue()
    let box = Box()
    let allRan = expectation(description: "all operations ran")
    allRan.expectedFulfillmentCount = 100

    for index in 0..<100 {
      queue.enqueue {
        // Suspension points must not let later operations overtake.
        await Task.yield()
        box.append(index)
        allRan.fulfill()
      }
    }

    waitForExpectations(timeout: 10)
    XCTAssertEqual(box.values, Array(0..<100))
    queue.shutdown()
  }

  func testSampleChunkerEmitsExactChunks() {
    let chunker = SampleChunker(chunkSize: 4096)
    XCTAssertTrue(chunker.push(Array(repeating: 0, count: 4095)).isEmpty)
    let chunks = chunker.push(Array(repeating: 0, count: 4097))
    XCTAssertEqual(chunks.count, 2)
    XCTAssertTrue(chunks.allSatisfy { $0.count == 4096 })
  }

  /// The WAV sink must produce a finalized, readable 16 kHz mono int16 file
  /// whose frame count matches exactly what was written, and closing must be
  /// idempotent with post-close writes as safe no-ops.
  func testWavSinkWritesFinalizedWav() throws {
    let path = NSTemporaryDirectory() + "wav_sink_test_\(UUID().uuidString).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let sink = try WavSink(path: path)
    let tone: [Float] = (0..<16000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    sink.write(tone)
    sink.write(tone)
    sink.close()
    sink.write(tone)  // no-op after close
    sink.close()  // idempotent

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    XCTAssertEqual(file.fileFormat.sampleRate, 16000)
    XCTAssertEqual(file.fileFormat.channelCount, 1)
    XCTAssertEqual(file.length, 32000)  // both writes, nothing after close

    // Round-trip: the audio content survives the int16 conversion.
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let read = buffer.floatChannelData![0]
    for index in stride(from: 0, to: 16000, by: 1000) {
      XCTAssertEqual(read[index], tone[index], accuracy: 0.001)
    }
  }

  func testWavSinkRejectsUnwritablePath() {
    XCTAssertThrowsError(
      try WavSink(path: "/nonexistent-root-dir/nested/out.wav"))
  }

  /// Pins the tee itself, not just the sink: samples pushed through
  /// AudioFanout.dispatch must land in the WAV file.
  func testAudioFanoutTeesIntoWavSink() throws {
    final class NullFrames: FrameEmitting {
      func emit(samples: [Float]) {}
    }

    let path = NSTemporaryDirectory() + "fanout_tee_test_\(UUID().uuidString).wav"
    defer { try? FileManager.default.removeItem(atPath: path) }

    let fanout = AudioFanout(
      attachments: AudioFanout.Attachments(asr: [], eou: [], vad: [], emitFrames: false),
      frames: NullFrames(),
      vadEvents: VadEventsHandler(),
      wav: try WavSink(path: path)
    )
    let tone: [Float] = (0..<8000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
    fanout.dispatch(tone)
    fanout.dispatch(tone)
    fanout.closeWav()

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    XCTAssertEqual(file.length, 16000)
  }

  func testEchoFloatsReturnsIdenticalBytes() {
    let api = SystemHostApiImpl(debugEvents: DebugEventsHandler())
    let samples: [Float] = (0..<16000).map { Float($0 % 100) / 100 }
    let input = AudioBridge.typedData(from: samples)

    let resultExpectation = expectation(description: "echoFloats completes")
    api.echoFloats(samples: input) { result in
      switch result {
      case .success(let output):
        XCTAssertEqual(output.data, input.data)
      case .failure(let error):
        XCTFail("echoFloats failed: \(error)")
      }
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 5)
  }
}
