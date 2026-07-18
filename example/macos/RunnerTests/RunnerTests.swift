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
