import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

class FailingDropFile implements DataReaderFile {
  const FailingDropFile([this.message = 'simulated read failure']);

  final String message;

  @override
  String? get fileName => 'broken.png';

  @override
  int? get fileSize => null;

  @override
  Future<Uint8List> readAll() => Future.error(StateError(message));

  @override
  Stream<Uint8List> getStream() => Stream.error(StateError(message));

  @override
  void close() {}
}

class FailingDropReader extends DataReader {
  @override
  List<DataFormat> getFormats(List<DataFormat> allFormats) => allFormats;

  @override
  ReadProgress? getValue<T extends Object>(
    ValueFormat<T> format,
    AsyncValueChanged<T?> onValue, {
    ValueChanged<Object>? onError,
  }) =>
      null;

  @override
  ReadProgress? getFile(
    FileFormat? format,
    AsyncValueChanged<DataReaderFile> onFile, {
    ValueChanged<Object>? onError,
    bool allowVirtualFiles = true,
    bool synthesizeFilesFromURIs = true,
  }) {
    unawaited(Future<void>.sync(() => onFile(const FailingDropFile())));
    return null;
  }

  @override
  bool isSynthesized(DataFormat format) => false;

  @override
  bool isVirtual(DataFormat format) => false;

  @override
  List<PlatformFormat> get platformFormats => const [];

  @override
  Future<String?> getSuggestedName() async => 'broken.png';

  @override
  Future<VirtualFileReceiver?> getVirtualFileReceiver(
          {FileFormat? format}) async =>
      null;
}

class FakeDropItem with Diagnosticable implements DropItem {
  FakeDropItem(this.reader);

  final DataReader? reader;

  @override
  bool canProvide(DataFormat f) => true;

  @override
  bool hasValue(DataFormat f) => canProvide(f);

  @override
  DataReader? get dataReader => reader;

  @override
  Object? get localData => null;

  @override
  List<PlatformFormat> get platformFormats => const [];
}

class FakeDropSession with Diagnosticable implements DropSession {
  FakeDropSession(DataReader? reader) : items = [FakeDropItem(reader)];

  @override
  final List<DropItem> items;

  @override
  Set<DropOperation> get allowedOperations => {DropOperation.copy};

  @override
  Listenable get onDisposed => const _NeverChangedListenable();
}

class _NeverChangedListenable implements Listenable {
  const _NeverChangedListenable();

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

PerformDropEvent failingImageDropEvent() => PerformDropEvent(
      session: FakeDropSession(FailingDropReader()),
      position: DropPosition(local: Offset.zero, global: Offset.zero),
      acceptedOperation: DropOperation.copy,
    );
