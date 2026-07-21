/// Temporary switches for features whose implementation is intentionally kept
/// in the codebase while the feature is not exposed to users.
abstract final class FeatureFlags {
  static bool get overridePrompt => true;
}
