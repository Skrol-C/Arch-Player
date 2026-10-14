import 'dart:convert';

/// Extension manifest: the contract every .sflx package declares.
/// Parsed defensively - a hostile or sloppy manifest degrades to
/// rejection, never a crash. Field names follow the community
/// registry shape so compatible packages load as-is.
class ExtensionManifest {
  final String name;
  final String displayName;
  final String version;
  final String description;
  final List<String> types;
  final ExtensionPermissions permissions;
  final List<ExtensionSetting> settings;
  final List<QualityOption> qualityOptions;
  final String? icon;

  const ExtensionManifest({
    required this.name,
    required this.displayName,
    required this.version,
    required this.description,
    required this.types,
    required this.permissions,
    this.settings = const [],
    this.qualityOptions = const [],
    this.icon,
  });

  static const validTypes = {
    'metadata_provider',
    'download_provider',
    'lyrics_provider',
  };

  /// Null = invalid manifest. Reasons logged by the caller.
  static ExtensionManifest? parse(Map m) {
    try {
      final name = (m['name'] as String?)?.trim() ?? '';
      if (!RegExp(r'^[a-z0-9][a-z0-9._-]{0,127}$').hasMatch(name)) {
        return null;
      }
      final types = [
        for (final t in (m['type'] as List? ?? []))
          if (t is String) t,
      ];
      if (types.isEmpty || types.any((t) => !validTypes.contains(t))) {
        return null;
      }
      final version = (m['version'] as String?) ?? '?';
      final perms = m['permissions'];
      final network = [
        for (final h in ((perms is Map ? perms['network'] : null) as List? ?? []))
          if (h is String && h.isNotEmpty) h,
      ];
      return ExtensionManifest(
        name: name,
        displayName: (m['displayName'] as String?) ?? name,
        version: version,
        description: (m['description'] as String?) ?? '',
        types: types,
        permissions: ExtensionPermissions(
          network: network,
          storage: perms is Map && perms['storage'] == true,
          file: perms is Map && perms['file'] == true,
        ),
        settings: [
          for (final s in (m['settings'] as List? ?? []))
            if (s is Map && ExtensionSetting.parse(s) != null)
              ExtensionSetting.parse(s)!,
        ],
        qualityOptions: [
          for (final q in (m['qualityOptions'] as List? ?? []))
            if (q is Map && QualityOption.parse(q) != null)
              QualityOption.parse(q)!,
        ],
        icon: m['icon'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  bool get isMetadata => types.contains('metadata_provider');
  bool get isDownload => types.contains('download_provider');
  bool get isLyrics => types.contains('lyrics_provider');
}

class ExtensionPermissions {
  final List<String> network;
  final bool storage;
  final bool file;

  const ExtensionPermissions({
    this.network = const [],
    this.storage = false,
    this.file = false,
  });
}

class ExtensionSetting {
  final String key;
  final String label;
  final String type;
  final String description;
  final bool required;
  final String? def;
  final List<String> options;

  const ExtensionSetting({
    required this.key,
    required this.label,
    required this.type,
    this.description = '',
    this.required = false,
    this.def,
    this.options = const [],
  });

  static const validTypes = {'string', 'boolean', 'select'};

  static ExtensionSetting? parse(Map m) {
    final key = (m['key'] as String?) ?? '';
    final type = (m['type'] as String?) ?? '';
    if (key.isEmpty || !validTypes.contains(type)) return null;
    if (type == 'select') {
      final opts = (m['options'] as List?) ?? [];
      if (opts.isEmpty) return null;
    }
    return ExtensionSetting(
      key: key,
      label: (m['label'] as String?) ?? key,
      type: type,
      description: (m['description'] as String?) ?? '',
      required: m['required'] == true,
      def: m['default']?.toString(),
      options: [
        for (final o in (m['options'] as List? ?? [])) o.toString(),
      ],
    );
  }
}

class QualityOption {
  final String id;
  final String label;
  final String description;

  const QualityOption(
      {required this.id, required this.label, this.description = ''});

  static QualityOption? parse(Map m) {
    final id = (m['id'] as String?) ?? '';
    if (id.isEmpty) return null;
    return QualityOption(
      id: id,
      label: (m['label'] as String?) ?? id,
      description: (m['description'] as String?) ?? '',
    );
  }
}

/// Installed record: registry metadata + local state. Serialized
/// to prefs; the manifest itself is re-read from disk on demand.
class InstalledExtension {
  final String id;
  final String displayName;
  final String version;
  final String description;
  final List<String> roles;
  final bool enabled;
  final int priority;

  const InstalledExtension({
    required this.id,
    required this.displayName,
    required this.version,
    required this.description,
    required this.roles,
    this.enabled = true,
    this.priority = 0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'version': version,
        'description': description,
        'roles': roles,
        'enabled': enabled,
        'priority': priority,
      };

  static InstalledExtension? fromJson(Map m) {
    try {
      return InstalledExtension(
        id: (m['id'] as String?) ?? '',
        displayName: (m['displayName'] as String?) ?? '',
        version: (m['version'] as String?) ?? '?',
        description: (m['description'] as String?) ?? '',
        roles: [
          for (final r in (m['roles'] as List? ?? [])) r.toString(),
        ],
        enabled: (m['enabled'] as bool?) ?? true,
        priority: (m['priority'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  InstalledExtension copyWith({bool? enabled, int? priority}) =>
      InstalledExtension(
        id: id,
        displayName: displayName,
        version: version,
        description: description,
        roles: roles,
        enabled: enabled ?? this.enabled,
        priority: priority ?? this.priority,
      );

  Map<String, dynamic> toJsonString() => toJson();
}

/// Decode helper for prefs storage (kept beside the model so the
/// store never hand-rolls JSON twice).
List<InstalledExtension> decodeInstalledList(String body) {
  try {
    final list = jsonDecode(body) as List;
    return [
      for (final e in list)
        if (e is Map && InstalledExtension.fromJson(e) != null)
          InstalledExtension.fromJson(e)!,
    ];
  } catch (_) {
    return const [];
  }
}
