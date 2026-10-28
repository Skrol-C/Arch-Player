import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Settings glyphs, Mornye grammar: Cupertino counterparts for the
/// shared Material row icons. Directional chevrons use the mirroring
/// glyphs, not the fixed ones. Icons without a Cupertino counterpart
/// keep their Material shape. A wrong glyph is worse than a
/// mixed set.
IconData settingIconFor(IconData icon) {
  if (icon.fontFamily == CupertinoIcons.iconFont) return icon;
  return switch (icon) {
    Icons.extension_rounded ||
    Icons.extension ||
    Icons.extension_outlined ||
    Icons.apps =>
      CupertinoIcons.square_grid_2x2,
    Icons.store_rounded || Icons.store => CupertinoIcons.bag,
    Icons.volunteer_activism_rounded ||
    Icons.volunteer_activism ||
    Icons.favorite_outline ||
    Icons.favorite_border =>
      CupertinoIcons.heart,
    Icons.palette_rounded || Icons.palette || Icons.palette_outlined =>
      CupertinoIcons.paintbrush,
    Icons.library_music_rounded ||
    Icons.library_music ||
    Icons.library_music_outlined ||
    Icons.playlist_play_outlined ||
    Icons.queue_music_outlined =>
      CupertinoIcons.music_note_list,
    Icons.dns_rounded ||
    Icons.dns ||
    Icons.dns_outlined ||
    Icons.storage_outlined ||
    Icons.sd_storage_outlined =>
      CupertinoIcons.tray,
    Icons.hub_rounded || Icons.hub_outlined => CupertinoIcons.link,
    Icons.lyrics_rounded ||
    Icons.lyrics ||
    Icons.lyrics_outlined ||
    Icons.subtitles_outlined =>
      CupertinoIcons.quote_bubble,
    Icons.tune_rounded ||
    Icons.tune ||
    Icons.tune_outlined =>
      CupertinoIcons.slider_horizontal_3,
    Icons.download_rounded ||
    Icons.download ||
    Icons.download_outlined ||
    Icons.file_download_outlined =>
      CupertinoIcons.arrow_down_circle,
    Icons.folder_rounded ||
    Icons.folder ||
    Icons.folder_outlined ||
    Icons.folder_open =>
      CupertinoIcons.folder,
    Icons.phone_android_rounded ||
    Icons.phone_android ||
    Icons.system_update_rounded ||
    Icons.computer =>
      CupertinoIcons.device_phone_portrait,
    Icons.bolt_rounded || Icons.bolt || Icons.flash_on => CupertinoIcons.bolt,
    Icons.cleaning_services_rounded ||
    Icons.cleaning_services ||
    Icons.cleaning_services_outlined =>
      CupertinoIcons.sparkles,
    Icons.backup_rounded ||
    Icons.backup ||
    Icons.settings_backup_restore =>
      CupertinoIcons.arrow_clockwise,
    Icons.receipt_long_rounded ||
    Icons.receipt_long ||
    Icons.article_outlined ||
    Icons.source_outlined ||
    Icons.insert_drive_file_outlined =>
      CupertinoIcons.doc_text,
    Icons.info_outline_rounded ||
    Icons.info_outline ||
    Icons.info =>
      CupertinoIcons.info,
    Icons.history_rounded ||
    Icons.history ||
    Icons.history_toggle_off_outlined =>
      CupertinoIcons.clock,
    Icons.list_rounded || Icons.list || Icons.view_list => CupertinoIcons.list_bullet,
    Icons.chevron_right_rounded ||
    Icons.chevron_right ||
    Icons.arrow_forward =>
      CupertinoIcons.forward,
    Icons.arrow_back || Icons.chevron_left => CupertinoIcons.back,
    Icons.search_rounded || Icons.search => CupertinoIcons.search,
    Icons.play_circle_rounded ||
    Icons.play_circle ||
    Icons.play_circle_outline =>
      CupertinoIcons.play_circle,
    Icons.pause_circle_filled_rounded => CupertinoIcons.pause_circle_fill,
    Icons.shuffle_rounded || Icons.shuffle => CupertinoIcons.shuffle,
    Icons.repeat_rounded || Icons.repeat || Icons.repeat_one_rounded =>
      CupertinoIcons.repeat,
    Icons.music_note_rounded ||
    Icons.music_note ||
    Icons.music_note_outlined ||
    Icons.audiotrack_rounded ||
    Icons.audiotrack =>
      CupertinoIcons.music_note,
    Icons.person_rounded || Icons.person || Icons.person_outline =>
      CupertinoIcons.person,
    Icons.cloud_rounded ||
    Icons.cloud ||
    Icons.cloud_outlined =>
      CupertinoIcons.cloud,
    Icons.high_quality => CupertinoIcons.hifispeaker,
    Icons.speed_rounded || Icons.speed => CupertinoIcons.gauge,
    Icons.tag || Icons.sell_outlined || Icons.label_outline => CupertinoIcons.tag,
    Icons.language ||
    Icons.language_outlined ||
    Icons.translate ||
    Icons.public =>
      CupertinoIcons.globe,
    Icons.dark_mode => CupertinoIcons.moon,
    Icons.light_mode => CupertinoIcons.sun_max,
    Icons.contrast_rounded || Icons.contrast => CupertinoIcons.circle_lefthalf_fill,
    Icons.image_outlined ||
    Icons.wallpaper ||
    Icons.photo ||
    Icons.photo_outlined =>
      CupertinoIcons.photo,
    Icons.refresh_rounded || Icons.refresh || Icons.update => CupertinoIcons.arrow_clockwise,
    Icons.share_outlined || Icons.ios_share || Icons.share => CupertinoIcons.share,
    Icons.add_rounded || Icons.add => CupertinoIcons.add,
    Icons.delete_outline_rounded ||
    Icons.delete_outline ||
    Icons.delete_forever =>
      CupertinoIcons.trash,
    Icons.open_in_new_rounded || Icons.open_in_new => CupertinoIcons.arrow_up_right_square,
    Icons.error_outline => CupertinoIcons.exclamationmark_circle,
    Icons.check_circle_rounded ||
    Icons.check_circle ||
    Icons.check_circle_outline =>
      CupertinoIcons.checkmark_circle,
    Icons.cancel_rounded || Icons.cancel_outlined => CupertinoIcons.xmark_circle,
    Icons.hourglass_empty_rounded => CupertinoIcons.hourglass,
    Icons.inbox_rounded || Icons.inbox => CupertinoIcons.tray,
    Icons.bug_report_outlined || Icons.bug_report => CupertinoIcons.ant,
    _ => icon,
  };
}
