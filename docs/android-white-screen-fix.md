# Android white screen after launch

## Symptom

Some Android APK builds can install successfully but stay on the launch screen, showing only the white Android launch background and app icon. The Flutter first frame never appears.

## Root cause

The Android logcat from the broken APK showed Flutter plugin registration failing before the app UI was ready:

```text
dlopen failed: library "libirondash_engine_context_native.so" not found
Error registering plugin irondash_engine_context
java.lang.UnsatisfiedLinkError: dlopen failed: library "libirondash_engine_context_native.so" not found

dlopen failed: library "libsuper_native_extensions.so" not found
Error registering plugin super_native_extensions
java.lang.UnsatisfiedLinkError: dlopen failed: library "libsuper_native_extensions.so" not found
```

These libraries are pulled in by `super_drag_and_drop` / `super_clipboard` through `super_native_extensions`. CasRand Forge only needs these features for desktop-style drag-and-drop and native image transfer. Android should continue to use tap/file-picker flows instead.

The default Flutter Android plugin registrant catches `Exception`, but `UnsatisfiedLinkError` is an `Error`, so the missing optional native library can abort plugin registration and leave the app stuck before `runApp` completes. Even after making registration tolerant, constructing `DropRegion` on Android can trigger the same missing-library path.

## Fix

Android now treats the desktop native-transfer plugins as optional:

- `MainActivity` manually registers plugins one by one and catches `Throwable`, so a missing optional desktop-transfer native library cannot block the whole Flutter engine.
- `supportsSuperNativeExtensions` only enables `super_native_extensions` UI paths on desktop platforms: macOS, Windows, and Linux.
- Android skips `DropRegion`, `DragItemWidget`, and `DraggableWidget` wrappers while preserving the existing tap-to-select image/file flows.

This keeps desktop drag-and-drop behavior intact while allowing Android to boot normally without the optional native libraries.

## Verification

Validated on an Android API 36 arm64 emulator:

- APK installs successfully.
- Launch reaches the Flutter welcome dialog and main navigation instead of staying on the Android launch screen.
- Switching between the three main tabs logs no `E/flutter`, `Unhandled`, `PlatformException`, or `UnsatisfiedLinkError` after startup.
- `flutter test --reporter compact` passes.
- `flutter analyze --no-fatal-infos` passes with only existing info-level warnings.
- APK archive and signature verification pass with `unzip -t` and `apksigner verify`.

## Notes

The current public Android beta APK uses the debug signing key. It is suitable for beta testing, but not for a long-lived production Android release key. If testers installed a previous APK with a different signing key, Android may require uninstalling the old package before installing the fixed APK, which removes that package's local app data.

## 0.9.2 Beta cumulative updates

This Android Beta 3 build also includes the previously released 0.9.2 Beta feature set:

- Beta 1: drag-and-drop export for generated images, raw PNG copy/show-in-Finder flows, metadata import compatibility fixes, V4.5 metadata mapping, sequential-repeat prompts, and the initial public cross-platform rebrand.
- Beta 2: per-image generation count/interval scheduling, generation-page layout cleanup, the move of image size/random seed into image-generation settings, and removal of the old override-prompt UI from the generation page.
- Beta 3: redesigned prompt settings with up to 6 characters, AI's Choice / gender controls, the moved and cascading negative prompt section, restore-initial-settings flow, updated default generation parameters, and the Android white-screen launch fix described above.
