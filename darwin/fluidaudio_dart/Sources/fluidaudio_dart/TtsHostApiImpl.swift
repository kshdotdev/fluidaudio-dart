import FluidAudio
import Foundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#endif

final class KokoroInstance {
  let manager: KokoroAneManager

  init(manager: KokoroAneManager) {
    self.manager = manager
  }
}

final class PocketInstance {
  let manager: PocketTtsManager

  init(manager: PocketTtsManager) {
    self.manager = manager
  }
}

final class ClonedVoiceInstance {
  let voiceData: PocketTtsVoiceData

  init(voiceData: PocketTtsVoiceData) {
    self.voiceData = voiceData
  }
}

/// Streams PocketTTS synthesis frames (80 ms at 24 kHz).
final class TtsChunksHandler: TtsChunksStreamHandler {
  private var sink: PigeonEventSink<TtsChunkMessage>?

  override func onListen(withArguments arguments: Any?, sink: PigeonEventSink<TtsChunkMessage>) {
    self.sink = sink
  }

  override func onCancel(withArguments arguments: Any?) {
    sink = nil
  }

  func emit(streamToken: Int64, frame: PocketTtsSynthesizer.AudioFrame) {
    send(
      TtsChunkMessage(
        streamToken: streamToken,
        samples: AudioBridge.typedData(from: frame.samples),
        frameIndex: Int64(frame.frameIndex),
        chunkIndex: Int64(frame.chunkIndex),
        chunkCount: Int64(frame.chunkCount),
        isLast: false
      ))
  }

  /// Ordered end-of-stream marker: emitted on the same channel after the last
  /// frame, so Dart closes without racing the method-channel reply.
  func emitEnd(streamToken: Int64) {
    send(
      TtsChunkMessage(
        streamToken: streamToken,
        samples: AudioBridge.typedData(from: []),
        frameIndex: -1,
        chunkIndex: -1,
        chunkCount: -1,
        isLast: true
      ))
  }

  private func send(_ message: TtsChunkMessage) {
    if Thread.isMainThread {
      sink?.success(message)
    } else {
      DispatchQueue.main.async { [weak self] in self?.sink?.success(message) }
    }
  }
}

final class TtsHostApiImpl: TtsHostApi {
  private let registry: InstanceRegistry
  private let downloadProgress: DownloadProgressHandler
  private let chunks: TtsChunksHandler

  init(
    registry: InstanceRegistry,
    downloadProgress: DownloadProgressHandler,
    chunks: TtsChunksHandler
  ) {
    self.registry = registry
    self.downloadProgress = downloadProgress
    self.chunks = chunks
  }

  private static func variant(for message: KokoroVariantMessage) -> KokoroAneVariant {
    switch message {
    case .english: return .english
    case .mandarin: return .mandarin
    case .japanese: return .japanese
    }
  }

  func kokoroCreate(
    variant: KokoroVariantMessage, defaultVoice: String?, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    let kokoroVariant = Self.variant(for: variant)
    Task {
      do {
        _ = try await KokoroAneResourceDownloader.ensureModels(
          variant: kokoroVariant, progressHandler: handler)
        let manager = KokoroAneManager(variant: kokoroVariant, defaultVoice: defaultVoice)
        try await manager.initialize()
        let id = self.registry.add(KokoroInstance(manager: manager))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func kokoroSynthesizeWav(
    instanceId: Int64, text: String, voice: String?, speed: Double,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: KokoroInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "Kokoro TTS")))
      return
    }
    Task {
      do {
        let wav = try await instance.manager.synthesize(
          text: text, voice: voice, speed: Float(speed))
        completion(.success(FlutterStandardTypedData(bytes: wav)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func kokoroSynthesizeDetailed(
    instanceId: Int64, text: String, voice: String?, speed: Double,
    completion: @escaping (Result<TtsResultMessage, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: KokoroInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "Kokoro TTS")))
      return
    }
    Task {
      do {
        let result = try await instance.manager.synthesizeDetailed(
          text: text, voice: voice, speed: Float(speed))
        let wav = try AudioWAV.data(
          from: result.samples, sampleRate: Double(result.sampleRate))
        completion(
          .success(
            TtsResultMessage(
              samples: AudioBridge.typedData(from: result.samples),
              sampleRate: Int64(result.sampleRate),
              wav: FlutterStandardTypedData(bytes: wav)
            )))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func pocketCreate(
    defaultVoice: String?, progressToken: Int64,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    let handler = downloadProgress.progressHandler(for: progressToken)
    Task {
      do {
        _ = try await PocketTtsResourceDownloader.ensureModels(
          language: .english, progressHandler: handler)
        let manager = PocketTtsManager(
          defaultVoice: defaultVoice ?? PocketTtsConstants.defaultVoice)
        try await manager.initialize()
        let id = self.registry.add(PocketInstance(manager: manager))
        self.downloadProgress.emitCompleted(progressToken: progressToken)
        completion(.success(id))
      } catch {
        self.downloadProgress.emitFailed(progressToken: progressToken, error: error)
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func pocketSynthesizeWav(
    instanceId: Int64, text: String, voice: String?, temperature: Double,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: PocketInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "PocketTTS")))
      return
    }
    Task {
      do {
        let wav = try await instance.manager.synthesize(
          text: text, voice: voice, temperature: Float(temperature))
        completion(.success(FlutterStandardTypedData(bytes: wav)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func pocketSynthesizeStreaming(
    instanceId: Int64, text: String, voice: String?, temperature: Double, streamToken: Int64,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: PocketInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "PocketTTS")))
      return
    }
    let chunks = self.chunks
    Task {
      do {
        let stream = try await instance.manager.synthesizeStreaming(
          text: text, voice: voice, temperature: Float(temperature))
        for try await frame in stream {
          chunks.emit(streamToken: streamToken, frame: frame)
        }
        chunks.emitEnd(streamToken: streamToken)
        completion(.success(()))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func pocketCloneVoice(
    instanceId: Int64, float32Samples24k: FlutterStandardTypedData,
    completion: @escaping (Result<Int64, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: PocketInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "PocketTTS")))
      return
    }
    let samples = AudioBridge.floats(from: float32Samples24k)
    Task {
      do {
        let voiceData = try await instance.manager.cloneVoice(from: samples)
        completion(.success(self.registry.add(ClonedVoiceInstance(voiceData: voiceData))))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func pocketSynthesizeWithVoice(
    instanceId: Int64, voiceId: Int64, text: String, temperature: Double,
    completion: @escaping (Result<FlutterStandardTypedData, Error>) -> Void
  ) {
    guard let instance = registry.get(instanceId, as: PocketInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(instanceId, kind: "PocketTTS")))
      return
    }
    guard let voice = registry.get(voiceId, as: ClonedVoiceInstance.self) else {
      completion(.failure(ErrorMapping.instanceNotFound(voiceId, kind: "cloned voice")))
      return
    }
    Task {
      do {
        let wav = try await instance.manager.synthesize(
          text: text, voiceData: voice.voiceData, temperature: Float(temperature))
        completion(.success(FlutterStandardTypedData(bytes: wav)))
      } catch {
        completion(.failure(ErrorMapping.map(error)))
      }
    }
  }

  func dispose(instanceId: Int64, completion: @escaping (Result<Void, Error>) -> Void) {
    let removed = registry.remove(instanceId)
    if let kokoro = removed as? KokoroInstance {
      Task {
        await kokoro.manager.cleanup()
        completion(.success(()))
      }
    } else if let pocket = removed as? PocketInstance {
      Task {
        await pocket.manager.cleanup()
        completion(.success(()))
      }
    } else {
      completion(.success(()))
    }
  }
}
