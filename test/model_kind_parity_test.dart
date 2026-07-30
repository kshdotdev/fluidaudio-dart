import 'package:flutter_test/flutter_test.dart';
import 'package:fluidaudio_dart/fluidaudio_dart.dart';
import 'package:fluidaudio_dart/src/messages.g.dart' as messages;

/// `FluidModels._kind` bridges `ModelKind` → `ModelKindMessage` **by ordinal
/// index** (lib/src/models.dart), so the two enums are one silent-corruption
/// bug apart: reordering or inserting a case in either declaration would send
/// every later kind to the wrong native repo without a compile error.
///
/// This is the guard for that coupling. Both enums are **append-only**.
void main() {
  test('ModelKind and ModelKindMessage declare the same cases in order', () {
    expect(
      ModelKind.values.map((kind) => kind.name).toList(),
      messages.ModelKindMessage.values.map((kind) => kind.name).toList(),
    );
  });

  test('every ModelKind index addresses the same-named pigeon case', () {
    for (final kind in ModelKind.values) {
      expect(messages.ModelKindMessage.values[kind.index].name, kind.name);
    }
  });
}
