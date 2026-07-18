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
