import 'dart:typed_data';

/// Default build: no person detection (the build with "ml" enabled replaces
/// this file with the ML Kit version).
const bool kPersonSupported = false;

Future<bool> detectPerson(Uint8List png) async => false;
