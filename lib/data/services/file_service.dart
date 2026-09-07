import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:universal_html/html.dart' as html;
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:saver_gallery/saver_gallery.dart';

enum GeneratedImageSaveDestination {
  fileSystem,
  androidGallery,
  webDownload,
}

class GeneratedImageSaveResult {
  const GeneratedImageSaveResult({
    required this.destination,
    this.path,
  });

  final GeneratedImageSaveDestination destination;
  final String? path;
}

class AndroidGalleryWriteResult {
  const AndroidGalleryWriteResult({
    required this.isSuccess,
    this.errorMessage,
  });

  final bool isSuccess;
  final String? errorMessage;
}

abstract interface class AndroidGalleryWriter {
  Future<bool> requestPermission();

  Future<AndroidGalleryWriteResult> saveImage(
    Uint8List bytes, {
    required String name,
  });
}

class PlatformAndroidGalleryWriter implements AndroidGalleryWriter {
  PlatformAndroidGalleryWriter({
    Future<int> Function()? sdkIntProvider,
    Future<bool> Function()? legacyPermissionRequester,
    Future<AndroidGalleryWriteResult> Function(Uint8List, String)? imageSaver,
  })  : _sdkIntProvider = sdkIntProvider ?? _readSdkInt,
        _legacyPermissionRequester =
            legacyPermissionRequester ?? _requestLegacyPermission,
        _imageSaver = imageSaver ?? _saveWithPlugin;

  final Future<int> Function() _sdkIntProvider;
  final Future<bool> Function() _legacyPermissionRequester;
  final Future<AndroidGalleryWriteResult> Function(Uint8List, String)
      _imageSaver;

  @override
  Future<bool> requestPermission() async {
    if (await _sdkIntProvider() >= 29) return true;
    return _legacyPermissionRequester();
  }

  @override
  Future<AndroidGalleryWriteResult> saveImage(
    Uint8List bytes, {
    required String name,
  }) async {
    return _imageSaver(bytes, name);
  }

  static Future<int> _readSdkInt() async =>
      (await DeviceInfoPlugin().androidInfo).version.sdkInt;

  static Future<bool> _requestLegacyPermission() =>
      Permission.storage.request().isGranted;

  static Future<AndroidGalleryWriteResult> _saveWithPlugin(
    Uint8List bytes,
    String name,
  ) async {
    final result = await SaverGallery.saveImage(
      bytes,
      name: name,
      androidRelativePath: 'Pictures/nai-generated',
      androidExistNotSave: false,
    );
    return AndroidGalleryWriteResult(
      isSuccess: result.isSuccess,
      errorMessage: result.errorMessage,
    );
  }
}

class FileService {
  static final Set<String> _reservedImagePaths = {};
  static int _imageTemporarySequence = 0;
  FileService({
    AndroidGalleryWriter? androidGalleryWriter,
    TargetPlatform? targetPlatform,
    bool? isWeb,
  })  : _androidGalleryWriter =
            androidGalleryWriter ?? PlatformAndroidGalleryWriter(),
        _targetPlatform = targetPlatform,
        _isWeb = isWeb;

  final AndroidGalleryWriter _androidGalleryWriter;
  final TargetPlatform? _targetPlatform;
  final bool? _isWeb;

  bool get _runsOnWeb => _isWeb ?? kIsWeb;
  TargetPlatform get _platform {
    final override = _targetPlatform;
    if (override != null) return override;
    if (Platform.isMacOS) return TargetPlatform.macOS;
    if (Platform.isWindows) return TargetPlatform.windows;
    if (Platform.isLinux) return TargetPlatform.linux;
    if (Platform.isIOS) return TargetPlatform.iOS;
    return TargetPlatform.android;
  }

  Future<GeneratedImageSaveResult> saveGeneratedImage(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    final path = await savePictureToFile(bytes, fileName, saveDir);
    if (path != null) {
      return GeneratedImageSaveResult(
        destination: GeneratedImageSaveDestination.fileSystem,
        path: path,
      );
    }
    if (_runsOnWeb) {
      return const GeneratedImageSaveResult(
        destination: GeneratedImageSaveDestination.webDownload,
      );
    }
    if (_platform == TargetPlatform.android) {
      return const GeneratedImageSaveResult(
        destination: GeneratedImageSaveDestination.androidGallery,
      );
    }
    throw StateError('Generated image was not published to durable storage.');
  }

  Future<String?> savePictureToFile(
    Uint8List bytes,
    String fileName,
    String saveDir,
  ) async {
    if (_runsOnWeb) {
      // Web: download file as blob
      final blob = html.Blob([bytes]);
      final url = html.Url.createObjectUrlFromBlob(blob);
      var _ = html.AnchorElement(href: url)
        ..setAttribute("download", fileName)
        ..click();
      html.Url.revokeObjectUrl(url);
      return null;
    } else if (_platform == TargetPlatform.windows ||
        _platform == TargetPlatform.macOS) {
      // Desktop: create save path and write file
      final Directory targetDir;
      if (saveDir.isEmpty) {
        targetDir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}'
          '${Platform.pathSeparator}nai-generated',
        );
      } else {
        targetDir = Directory(saveDir);
      }
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      final file = File(
        '${targetDir.path}${Platform.pathSeparator}$fileName',
      );
      await writeNewImageFileAtomically(file, bytes);
      return file.absolute.path;
    } else if (_platform == TargetPlatform.android) {
      // Android: save as photo in Pictures/
      if (!await _androidGalleryWriter.requestPermission()) {
        throw StateError('Photo library permission was denied.');
      }
      final result = await _androidGalleryWriter.saveImage(
        bytes,
        name: fileName,
      );
      if (!result.isSuccess) {
        throw StateError(
          result.errorMessage ?? 'Android gallery rejected the image.',
        );
      }
      return null;
    }
    return null;
  }

  /// Publishes a new image without adopting an existing file, directory or
  /// link. Shared reservations cover PNG/JPEG writers across service instances.
  /// [beforePublish] lets an accepted storage job check cancellation at its
  /// final publication boundary without coupling this adapter to job state.
  static Future<void> writeNewImageFileAtomically(
    File finalFile,
    Uint8List bytes, {
    void Function()? beforePublish,
  }) async {
    final path = finalFile.absolute.path;
    if (!_reservedImagePaths.add(path)) {
      throw FileSystemException(
          'Another image is being saved to this path.', path);
    }
    File? temporary;
    RandomAccessFile? handle;
    Future<void> requireVacantPath() async {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw FileSystemException(
            'An existing image path will not be overwritten.', path);
      }
    }

    try {
      beforePublish?.call();
      final parent = finalFile.parent;
      if (!await parent.exists()) await parent.create(recursive: true);
      await requireVacantPath();
      // A short basename also works with near-limit generated filenames.
      temporary = File('${parent.path}${Platform.pathSeparator}.casrand-$pid-'
          '${DateTime.now().microsecondsSinceEpoch}-${_imageTemporarySequence++}.tmp');
      handle = await temporary.open(mode: FileMode.writeOnly);
      await handle.writeFrom(bytes);
      await handle.flush();
      await handle.close();
      handle = null;
      beforePublish?.call();
      await requireVacantPath();
      await temporary.rename(path);
    } finally {
      await handle?.close();
      if (temporary != null && await temporary.exists()) {
        await temporary.delete();
      }
      _reservedImagePaths.remove(path);
    }
  }

  Future<void> saveStringToFile(
    String content,
    String fileName,
  ) async {
    if (kIsWeb) {
      final bytes = Uint8List.fromList(utf8.encode(content));
      final blob = html.Blob([bytes]);
      final url = html.Url.createObjectUrlFromBlob(blob);
      var _ = html.AnchorElement(href: url)
        ..setAttribute("download", fileName)
        ..click();
      html.Url.revokeObjectUrl(url);
    } else if (Platform.isWindows || Platform.isMacOS) {
      final path = await FilePicker.platform.saveFile(fileName: fileName);
      if (path == null) return;
      final file = File(path);
      await file.writeAsBytes(utf8.encode(content));
    } else if (Platform.isAndroid) {
      await FilePicker.platform.saveFile(
        fileName: fileName,
        bytes: utf8.encode(content),
      );
    }
  }

  String generateRandomString() {
    const length = 6;
    const lettersAndDigits = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();

    return List.generate(
        length,
        (index) =>
            lettersAndDigits[random.nextInt(lettersAndDigits.length)]).join();
  }

  String generateTimestampString(DateTime time) {
    return '${time.year}'
        '${time.month.toString().padLeft(2, '0')}'
        '${time.day.toString().padLeft(2, '0')}'
        '${time.hour.toString().padLeft(2, '0')}'
        '${time.minute.toString().padLeft(2, '0')}'
        '${time.second.toString().padLeft(2, '0')}';
  }

  Future<Uint8List?> decryptAsset(String assetPath) async {
    const keyBase64 = String.fromEnvironment("ASSET_KEY_BASE64");
    const ivBase64 = String.fromEnvironment("ASSET_IV_BASE64");
    if (keyBase64.isEmpty || ivBase64.isEmpty) return null;
    try {
      final key = encrypt.Key.fromBase64(keyBase64);
      final iv = encrypt.IV.fromBase64(ivBase64);
      final encrypter = encrypt.Encrypter(encrypt.AES(key));
      final assetByteData = await rootBundle.load(assetPath);
      final encryptedBase64 = assetByteData.buffer.asUint8List();
      final decryptedBase64 =
          encrypter.decrypt(encrypt.Encrypted(encryptedBase64), iv: iv);
      final decryptedBytes = base64Decode(decryptedBase64);
      return decryptedBytes;
    } catch (exception) {
      return null;
    }
  }
}
