import AVFoundation
import FluidAudio
import Foundation
import os

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import CoreAudio
  import FlutterMacOS
#endif

/// Streams captured system-audio frames (16 kHz mono) for UI.
final class SystemAudioFramesHandler: SystemAudioFramesStreamHandler, FrameEmitting {
  private var sink: PigeonEventSink<MicFrameMessage>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<MicFrameMessage>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(samples: [Float]) {
    guard !samples.isEmpty else { return }
    let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
    let rms = Double((sumOfSquares / Float(samples.count)).squareRoot())
    let message = MicFrameMessage(samples: AudioBridge.typedData(from: samples), rms: rms)
    if Thread.isMainThread {
      sink?.success(message)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(message) }
    }
  }
}

#if os(macOS)
  /// One live system-audio capture via a Core Audio process tap (macOS 14.4+).
  ///
  /// Pattern: tap (global-excluding-self, or a PID mixdown) wrapped in a
  /// private tap-only aggregate device; the input format MUST come from the
  /// tap's ASBD (`kAudioTapPropertyFormat`) — never the aggregate's nominal
  /// rate, which mis-pitches the audio with mismatched output devices.
  @available(macOS 14.4, *)
  final class SystemAudioCapture {
    private let ioQueue = DispatchQueue(label: "fluidaudio_dart.systemaudio", qos: .userInitiated)
    private let fanoutQueue = SerialTaskQueue()
    private let converter = AudioConverter()
    private let runningState = OSAllocatedUnfairLock(initialState: false)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    var running: Bool {
      runningState.withLock { $0 }
    }

    deinit {
      stop()
    }

    func start(processIds: [Int64], fanout: AudioFanout) throws {
      // 1. Tap description: specific PIDs, or everything except this process.
      let description: CATapDescription
      if processIds.isEmpty {
        let selfObject = Self.translatePIDToProcessObject(getpid())
        let excluded = selfObject != AudioObjectID(kAudioObjectUnknown) ? [selfObject] : []
        description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
      } else {
        var objects: [AudioObjectID] = []
        for pid in processIds {
          let object = Self.translatePIDToProcessObject(pid_t(pid))
          if object != AudioObjectID(kAudioObjectUnknown) {
            objects.append(object)
          }
        }
        guard !objects.isEmpty else {
          throw PigeonError(
            code: "NoTappableProcess",
            message:
              "None of the given PIDs currently has an audio process object "
              + "(processes only become tappable once they open audio).",
            details: nil)
        }
        description = CATapDescription(stereoMixdownOfProcesses: objects)
      }
      description.name = "fluidaudio_dart tap"
      description.isPrivate = true
      description.muteBehavior = .unmuted

      var tap = AudioObjectID(kAudioObjectUnknown)
      var status = AudioHardwareCreateProcessTap(description, &tap)
      guard status == noErr else {
        throw PigeonError(
          code: "TapCreateFailed",
          message:
            "AudioHardwareCreateProcessTap failed (\(status)). "
            + "Check the System Audio Recording permission.",
          details: nil)
      }
      tapID = tap

      // 2. Private, tap-only aggregate device (auto-starts the tap).
      let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey as String: "fluidaudio_dart aggregate",
        kAudioAggregateDeviceUIDKey as String: UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey as String: true,
        kAudioAggregateDeviceTapAutoStartKey as String: true,
        kAudioAggregateDeviceTapListKey as String: [
          [kAudioSubTapUIDKey as String: description.uuid.uuidString]
        ],
      ]
      var aggregate = AudioObjectID(kAudioObjectUnknown)
      status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
      guard status == noErr else {
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
        throw PigeonError(
          code: "AggregateCreateFailed",
          message: "AudioHardwareCreateAggregateDevice failed (\(status))", details: nil)
      }
      aggregateID = aggregate

      // 3. Input format from the tap ASBD.
      guard let inputFormat = Self.tapStreamFormat(tapID) else {
        unwind()
        throw PigeonError(
          code: "TapFormatUnavailable", message: "Could not read the tap's stream format",
          details: nil)
      }

      // 4. IOProc on a dedicated queue; CoreAudio copies buffers before
      //    dispatch, so resampling inline here is safe.
      var procID: AudioDeviceIOProcID?
      status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
        [weak self] _, inInputData, _, _, _ in
        guard let self, self.running else { return }
        guard
          let buffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat, bufferListNoCopy: inInputData, deallocator: nil),
          buffer.frameLength > 0,
          let samples = try? self.converter.resampleBuffer(buffer)
        else { return }
        self.fanoutQueue.enqueue { fanout.dispatch(samples) }
      }
      guard status == noErr, let validProc = procID else {
        unwind()
        throw PigeonError(
          code: "IOProcCreateFailed",
          message: "AudioDeviceCreateIOProcIDWithBlock failed (\(status))", details: nil)
      }
      ioProcID = validProc

      status = AudioDeviceStart(aggregateID, validProc)
      guard status == noErr else {
        unwind()
        throw PigeonError(
          code: "DeviceStartFailed", message: "AudioDeviceStart failed (\(status))", details: nil)
      }
      runningState.withLock { $0 = true }
    }

    func stop() {
      let wasRunning = runningState.withLock { state in
        let previous = state
        state = false
        return previous
      }
      guard wasRunning else { return }
      if let procID = ioProcID {
        AudioDeviceStop(aggregateID, procID)
        // AudioDeviceStop does not wait for an in-flight callback; drain it
        // before tearing the chain down.
        ioQueue.sync {}
      }
      unwind()
      fanoutQueue.shutdown()
    }

    private func unwind() {
      if let procID = ioProcID {
        AudioDeviceDestroyIOProcID(aggregateID, procID)
        ioProcID = nil
      }
      if aggregateID != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        aggregateID = AudioObjectID(kAudioObjectUnknown)
      }
      if tapID != AudioObjectID(kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(tapID)
        tapID = AudioObjectID(kAudioObjectUnknown)
      }
    }

    static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var processPid = pid
      var objectID = AudioObjectID(kAudioObjectUnknown)
      var size = UInt32(MemoryLayout<AudioObjectID>.size)
      let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address,
        UInt32(MemoryLayout<pid_t>.size), &processPid, &size, &objectID)
      return status == noErr ? objectID : AudioObjectID(kAudioObjectUnknown)
    }

    static func tapStreamFormat(_ tapID: AudioObjectID) -> AVAudioFormat? {
      var address = AudioObjectPropertyAddress(
        mSelector: kAudioTapPropertyFormat,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      var asbd = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
      guard status == noErr else { return nil }
      return AVAudioFormat(streamDescription: &asbd)
    }

    /// Preflight: try to create (and immediately destroy) a throwaway tap.
    /// The first attempt triggers the System Audio Recording TCC prompt;
    /// there is no direct request API.
    static func preflightPermission() -> Bool {
      let selfObject = translatePIDToProcessObject(getpid())
      let excluded = selfObject != AudioObjectID(kAudioObjectUnknown) ? [selfObject] : []
      let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
      description.name = "fluidaudio_dart permission preflight"
      description.isPrivate = true
      var tap = AudioObjectID(kAudioObjectUnknown)
      let status = AudioHardwareCreateProcessTap(description, &tap)
      if status == noErr {
        AudioHardwareDestroyProcessTap(tap)
        return true
      }
      return false
    }
  }
#endif

final class SystemAudioHostApiImpl: SystemAudioHostApi {
  private let registry: InstanceRegistry
  private let frames: SystemAudioFramesHandler
  private let vadEvents: VadEventsHandler

  #if os(macOS)
    private var capture: Any?
  #endif

  init(registry: InstanceRegistry, frames: SystemAudioFramesHandler, vadEvents: VadEventsHandler) {
    self.registry = registry
    self.frames = frames
    self.vadEvents = vadEvents
  }

  private static var supported: Bool {
    #if os(macOS)
      if #available(macOS 14.4, *) { return true }
    #endif
    return false
  }

  func isSupported(completion: @escaping (Result<Bool, Error>) -> Void) {
    completion(.success(Self.supported))
  }

  func requestPermission(completion: @escaping (Result<Bool, Error>) -> Void) {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        // The TCC prompt (if any) is triggered by the create attempt; give
        // the answer for the current state.
        completion(.success(SystemAudioCapture.preflightPermission()))
        return
      }
    #endif
    completion(.success(false))
  }

  func start(
    processIds: [Int64], asrInstanceIds: [Int64], eouInstanceIds: [Int64], vadStreamIds: [Int64],
    emitFrames: Bool, completion: @escaping (Result<Void, Error>) -> Void
  ) {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        if (capture as? SystemAudioCapture)?.running == true {
          completion(
            .failure(
              PigeonError(
                code: "SystemAudioAlreadyRunning",
                message: "System-audio capture is already running", details: nil)))
          return
        }

        var asr: [StreamingAsrInstance] = []
        for id in asrInstanceIds {
          guard let instance = registry.get(id, as: StreamingAsrInstance.self) else {
            completion(.failure(ErrorMapping.instanceNotFound(id, kind: "streaming ASR")))
            return
          }
          asr.append(instance)
        }
        var eou: [EouInstance] = []
        for id in eouInstanceIds {
          guard let instance = registry.get(id, as: EouInstance.self) else {
            completion(.failure(ErrorMapping.instanceNotFound(id, kind: "EOU")))
            return
          }
          eou.append(instance)
        }
        var vad: [(id: Int64, instance: VadStreamInstance)] = []
        for id in vadStreamIds {
          guard let instance = registry.get(id, as: VadStreamInstance.self) else {
            completion(.failure(ErrorMapping.instanceNotFound(id, kind: "VAD stream")))
            return
          }
          vad.append((id: id, instance: instance))
        }

        let fanout = AudioFanout(
          attachments: AudioFanout.Attachments(
            asr: asr, eou: eou, vad: vad, emitFrames: emitFrames),
          frames: frames,
          vadEvents: vadEvents
        )
        let newCapture = SystemAudioCapture()
        do {
          try newCapture.start(processIds: processIds, fanout: fanout)
          capture = newCapture
          completion(.success(()))
        } catch {
          completion(.failure(ErrorMapping.map(error)))
        }
        return
      }
    #endif
    completion(
      .failure(
        PigeonError(
          code: "Unsupported",
          message: "System-audio capture requires macOS 14.4+", details: nil)))
  }

  func stop(completion: @escaping (Result<Void, Error>) -> Void) {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        (capture as? SystemAudioCapture)?.stop()
        capture = nil
      }
    #endif
    completion(.success(()))
  }

  func isRunning(completion: @escaping (Result<Bool, Error>) -> Void) {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        completion(.success((capture as? SystemAudioCapture)?.running == true))
        return
      }
    #endif
    completion(.success(false))
  }

  /// Stops any live capture; used by plugin teardown.
  func teardown() {
    #if os(macOS)
      if #available(macOS 14.4, *) {
        (capture as? SystemAudioCapture)?.stop()
        capture = nil
      }
    #endif
  }
}
