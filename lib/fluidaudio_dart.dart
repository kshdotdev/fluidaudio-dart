/// Flutter bindings for FluidAudio: on-device speech-to-text, voice activity
/// detection, speaker diarization and text-to-speech on Apple platforms
/// (CoreML / Apple Neural Engine).
library;

export 'src/asr.dart' show FluidAsr;
export 'src/events.dart' show FluidDownloadProgressFailure;
export 'src/exceptions.dart'
    show FluidAudioException, FluidDownloadException, FluidInstanceGoneException;
export 'src/models.dart' show FluidModels;
export 'src/streaming_asr.dart' show FluidStreamingAsr;
export 'src/system.dart' show FluidAudioSystem, FluidDebugEvent, FluidSystemInfo;
export 'src/types.dart';
export 'src/vad.dart' show FluidVad, FluidVadStream;
