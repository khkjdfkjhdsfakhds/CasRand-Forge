import 'dart:ffi' show Abi;

/// Match the running executable, including x64 emulation on an ARM computer.
bool get isWindowsArm64 => Abi.current() == Abi.windowsArm64;
