import AVFoundation
import Cocoa
import FluidAudio
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

  /// Pins the native cancellation contract without downloading CoreML
  /// models: cancel retains and awaits the actual task, is idempotent, and
  /// returns comfortably inside the two-second release budget when the task
  /// cooperates with Swift cancellation.
  func testInferenceOperationCancellationAwaitsTaskAndIsIdempotent() async throws {
    let store = InferenceOperationStore(operationKind: "test")
    let operation = try store.reserve(41)
    let started = expectation(description: "inference task started")
    let stopped = expectation(description: "inference task stopped")
    let task = Task<Void, Never> {
      started.fulfill()
      do {
        while true {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        }
      } catch {
        // Task.sleep observes cancellation immediately.
      }
      stopped.fulfill()
    }
    operation.attach(task)
    await fulfillment(of: [started], timeout: 1)

    let began = Date()
    async let firstCancel: Void = store.cancel(41)
    async let secondCancel: Void = store.cancel(41)
    _ = await (firstCancel, secondCancel)

    XCTAssertLessThan(Date().timeIntervalSince(began), 2)
    await fulfillment(of: [stopped], timeout: 1)
    XCTAssertEqual(store.activeCount, 1)
    store.finish(41)
    XCTAssertEqual(store.activeCount, 0)
    await store.cancel(41)  // Finished ids are successful no-ops.
  }

  /// Cancellation can race the tiny reserve/attach window. The request must
  /// wait for attachment and cancel that task rather than returning early.
  func testInferenceOperationCancellationBeforeAttachmentIsNotLost() async throws {
    let store = InferenceOperationStore(operationKind: "test")
    let operation = try store.reserve(42)
    let stopped = expectation(description: "late-attached task stopped")

    let cancellation = Task { await store.cancel(42) }
    await Task.yield()
    let task = Task<Void, Never> {
      do {
        try await Task.sleep(nanoseconds: 60_000_000_000)
      } catch {
        // Expected cancellation after attachment.
      }
      stopped.fulfill()
    }
    operation.attach(task)

    await cancellation.value
    await fulfillment(of: [stopped], timeout: 1)
    store.finish(42)
  }

  func testInferenceOperationCloseCancelsAllAndRejectsNewWork() async throws {
    let store = InferenceOperationStore(operationKind: "test")
    let first = try store.reserve(1)
    let second = try store.reserve(2)
    let stopped = expectation(description: "all inference tasks stopped")
    stopped.expectedFulfillmentCount = 2

    for operation in [first, second] {
      operation.attach(Task<Void, Never> {
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
          // Expected during close.
        }
        stopped.fulfill()
      })
    }

    await store.cancelAllAndClose()
    await store.cancelAllAndClose()  // Idempotent close.
    await fulfillment(of: [stopped], timeout: 1)
    XCTAssertEqual(store.activeCount, 0)
    XCTAssertThrowsError(try store.reserve(3)) { error in
      guard case InferenceOperationStoreError.closed("test") = error else {
        return XCTFail("Unexpected registration error: \(error)")
      }
    }
  }

  func testInferenceOperationRejectsDuplicateActiveIdentity() throws {
    let store = InferenceOperationStore(operationKind: "test")
    _ = try store.reserve(7)
    XCTAssertThrowsError(try store.reserve(7)) { error in
      guard case InferenceOperationStoreError.duplicate("test", 7) = error else {
        return XCTFail("Unexpected registration error: \(error)")
      }
    }
  }

  func testInferenceOperationDeliversCancellationHandlerExactlyOnce() async throws {
    final class Counter: @unchecked Sendable {
      private let lock = NSLock()
      private(set) var value = 0

      func increment() {
        lock.lock()
        value += 1
        lock.unlock()
      }
    }

    let store = InferenceOperationStore(operationKind: "test")
    let operation = try store.reserve(8)
    let counter = Counter()
    let cancellation = Task { await store.cancel(8) }
    await Task.yield()
    operation.attach(
      Task<Void, Never> {
        do {
          try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
          // Expected cancellation.
        }
      },
      onCancel: counter.increment)

    async let first: Void = cancellation.value
    async let second: Void = store.cancel(8)
    _ = await (first, second)

    XCTAssertEqual(counter.value, 1)
    store.finish(8)
  }

  func testOneShotResultCompletionIgnoresLaterTerminalResults() {
    var values: [Int] = []
    let completion = OneShotResultCompletion<Int> { result in
      if case .success(let value) = result {
        values.append(value)
      }
    }

    completion.resolve(.success(1))
    completion.resolve(.success(2))

    XCTAssertEqual(values, [1])
  }

  func testDiarizationCancellationSignalStopsAudioSourceReads() throws {
    let signal = DiarizationCancellationSignal()
    let source = CancellableDiarizationAudioSource(
      base: ArrayAudioSampleSource(samples: [0.1, 0.2]), cancellation: signal)
    var destination = [Float](repeating: 0, count: 2)
    try destination.withUnsafeMutableBufferPointer { buffer in
      try source.copySamples(into: buffer.baseAddress!, offset: 0, count: 2)
    }
    XCTAssertEqual(destination, [0.1, 0.2])

    signal.cancel()
    XCTAssertThrowsError(
      try destination.withUnsafeMutableBufferPointer { buffer in
        try source.copySamples(into: buffer.baseAddress!, offset: 0, count: 2)
      }
    ) { error in
      XCTAssertTrue(error is CancellationError)
    }
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
