import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/log.dart';
import '../../../core/theme.dart';
import '../setting_icons.dart';
import '../widgets/setting_bits.dart';
import 'updater_page.dart';

/// About: the app, its one contributor, who it stands on, and the
/// license it ships under. No links section yet; that arrives with
/// open-sourcing. No em-dashes in here, house rule for settings.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          _version = '${info.version}+${info.buildNumber}';
        });
      }
    } catch (e) {
      ArchLog.w('about', 'version read failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadVersion();
    LicenseRegistry.addLicense(_archLicense);
  }

  /// Arch's own license entry, so the stock licenses page names the
  /// app and its terms instead of only listing third-party packages.
  static Stream<LicenseEntry> _archLicense() async* {
    yield const LicenseEntryWithLineBreaks(
      ['Arch Player'],
      'GNU General Public License v3.0\n'
      '\n'
      'Copyright (C) 2026 Skrol-C\n'
      '\n'
      'Arch Player is free software: you can redistribute it and/or '
      'modify it under the terms of the GNU General Public License '
      'as published by the Free Software Foundation, version 3.\n'
      '\n'
      'Arch Player is distributed in the hope that it will be useful, '
      'but WITHOUT ANY WARRANTY; without even the implied warranty of '
      'MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the '
      'GNU General Public License for more details.\n'
      '\n'
      'Full text: https://www.gnu.org/licenses/gpl-3.0.html',
    );
  }

  Future<void> _open(String url) async {
    HapticFeedback.selectionClick();
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
    } catch (e) {
      ArchLog.w('about', 'open failed: $url ($e)');
    }
  }

  @override
  Widget build(BuildContext context) {
    ArchLog.i('nav', 'about open');
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Material(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: scheme.outline.withValues(alpha: 0.35),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.asset(
                      'assets/icon/app_logo.png',
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        color: archPink,
                        alignment: Alignment.center,
                        child: const Text(
                          'A',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 40,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Arch Player',
                    style: TextStyle(
                      color: scheme.onSurface,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _version.isEmpty ? 'v…' : 'v$_version',
                      style: TextStyle(
                        color: scheme.onSecondaryContainer,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Local-first music with Needle pulls. Art first, always.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SettingGroup(
            title: 'Contributors',
            children: [
              _PersonRow(
                username: 'Skrol-C',
                role: 'Lead developer and creator',
                onTap: () => _open('https://github.com/Skrol-C'),
              ),
            ],
          ),
          SettingGroup(
            title: 'Special thanks',
            children: [
              _ThanksCard(
                name: 'Mornye',
                handle: 'mornyeapp/Mornye by zarzet',
                body:
                    'Most of what Arch is derives from Mornye. Its extension '
                    'system, its download API, and a lot of its ideas live on '
                    'in this app, and none of it would have been possible '
                    'without it as an open reference. If you like Arch, '
                    'please check out Mornye first.',
                actionLabel: 'mornyeapp/Mornye on GitHub',
                onTap: () =>
                    _open('https://github.com/mornyeapp/Mornye'),
              ),
            ],
          ),
          const SettingGroup(
            title: 'Metadata lanes',
            children: [
              _LaneRow(
                name: 'Deezer',
                detail: 'Previews, charts, release data',
                asset: 'assets/providers/deezer.svg',
              ),
              _LaneRow(
                name: 'MusicBrainz',
                detail: 'Canonical releases and artist identity',
                letter: 'M',
              ),
              _LaneRow(
                name: 'Last.fm',
                detail: 'Charts and listener counts',
                letter: 'L',
              ),
              _LaneRow(
                name: 'fanart.tv',
                detail: 'Artist photos and logos',
                letter: 'F',
              ),
              _LaneRow(
                name: 'LRCLib',
                detail: 'Synced lyrics',
                letter: 'L',
              ),
              _LaneRow(
                name: 'iTunes',
                detail: 'Artwork and lookup fallback',
                letter: 'i',
              ),
              _LaneRow(
                name: 'GetSongBPM',
                detail: 'Tempo and musical key lookups',
                letter: 'G',
              ),
            ],
          ),
          SettingGroup(
            title: 'App',
            children: [
              SettingRow(
                icon: settingIconFor(Icons.info_outline),
                title: 'Version',
                subtitle: _version.isEmpty
                    ? 'Reading version…'
                    : 'v$_version',
                push: const UpdaterPage(),
              ),
              _LicensesRow(version: _version),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 4, 0),
            child: Text(
              '© 2026 Skrol-C. Licensed under the GNU General Public '
              'License v3.0.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One contributor: avatar from GitHub, name, role, chevron.
/// Tapping opens the profile.
class _PersonRow extends StatelessWidget {
  final String username;
  final String role;
  final VoidCallback onTap;

  const _PersonRow({
    required this.username,
    required this.role,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipOval(
        child: SizedBox(
          width: 44,
          height: 44,
          child: CachedNetworkImage(
            imageUrl: 'https://github.com/$username.png',
            fit: BoxFit.cover,
            memCacheWidth: 132,
            errorWidget: (_, _, _) => _Monogram(letter: username[0]),
            placeholder: (_, _) => _Monogram(letter: username[0]),
          ),
        ),
      ),
      title: Text(
        username,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
      subtitle: Text(
        role,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
      trailing: Icon(
        CupertinoIcons.forward,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

class _Monogram extends StatelessWidget {
  final String letter;
  const _Monogram({required this.letter});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface,
      alignment: Alignment.center,
      child: Text(
        letter.toUpperCase(),
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 20,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// Special thanks card: full wording, then a GitHub link row.
class _ThanksCard extends StatelessWidget {
  final String name;
  final String handle;
  final String body;
  final String actionLabel;
  final VoidCallback onTap;

  const _ThanksCard({
    required this.name,
    required this.handle,
    required this.body,
    required this.actionLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: ClipOval(
        child: SizedBox(
          width: 44,
          height: 44,
          child: CachedNetworkImage(
            imageUrl: 'https://github.com/mornyeapp.png',
            fit: BoxFit.cover,
            memCacheWidth: 132,
            errorWidget: (_, _, _) => const _Monogram(letter: 'M'),
            placeholder: (_, _) => const _Monogram(letter: 'M'),
          ),
        ),
      ),
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            handle,
            style: TextStyle(
              color: scheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              color: scheme.onSurface,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () {
              HapticFeedback.selectionClick();
              onTap();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    actionLabel,
                    style: const TextStyle(
                      color: Color(0xFFFC3C44),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    CupertinoIcons.arrow_up_right,
                    color: Color(0xFFFC3C44),
                    size: 14,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One metadata lane: the real provider mark when we ship its
/// artwork, a monogram tile otherwise. Never a generic icon that
/// pretends to be the provider.
class _LaneRow extends StatelessWidget {
  final String name;
  final String detail;
  final String? asset;
  final String? letter;

  const _LaneRow({
    required this.name,
    required this.detail,
    this.asset,
    this.letter,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mark = asset != null
        ? ClipOval(
            child: Container(
              width: 40,
              height: 40,
              color: scheme.surface,
              alignment: Alignment.center,
              child: SizedBox(
                width: 26,
                height: 26,
                child: SvgPicture.asset(asset!),
              ),
            ),
          )
        : Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(12),
            ),
            alignment: Alignment.center,
            child: Text(
              (letter ?? name.characters.first).toUpperCase(),
              style: TextStyle(
                color: scheme.onSurfaceVariant,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: mark,
      title: Text(
        name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        detail,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
      ),
    );
  }
}

/// Licenses row: opens the stock license page with our name on it.
class _LicensesRow extends StatelessWidget {
  final String version;

  const _LicensesRow({required this.version});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? Theme.of(context).colorScheme.surface
              : const Color(0xFFF6F6F8),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(
          CupertinoIcons.doc_text,
          color: Color(0xFFFC3C44),
        ),
      ),
      title: const Text(
        'Licenses',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: const Text(
        'GNU General Public License v3.0',
        style: TextStyle(fontSize: 13),
      ),
      trailing: Icon(
        CupertinoIcons.forward,
        size: 18,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      onTap: () {
        HapticFeedback.selectionClick();
        showLicensePage(
          context: context,
          applicationName: 'Arch Player',
          applicationVersion: version.isEmpty ? null : 'v$version',
          applicationLegalese: '© 2026 Skrol-C',
        );
      },
    );
  }
}
