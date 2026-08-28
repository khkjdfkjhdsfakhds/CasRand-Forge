class MetadataImportOptions {
  final bool prompt;
  final bool undesiredContent;
  final bool characters;
  final bool settings;
  final bool seed;
  final bool append;
  final bool cleanImports;

  const MetadataImportOptions({
    required this.prompt,
    required this.undesiredContent,
    required this.characters,
    required this.settings,
    required this.seed,
    this.append = false,
    this.cleanImports = false,
  });
}

class MetadataImportAvailability {
  final bool prompt;
  final bool undesiredContent;
  final bool characters;
  final bool settings;
  final bool seed;

  const MetadataImportAvailability({
    required this.prompt,
    required this.undesiredContent,
    required this.characters,
    required this.settings,
    required this.seed,
  });

  bool get hasAny =>
      prompt || undesiredContent || characters || settings || seed;
}
