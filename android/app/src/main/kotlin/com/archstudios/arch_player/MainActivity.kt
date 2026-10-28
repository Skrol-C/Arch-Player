package com.archstudios.arch_player

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentUris
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : com.ryanheise.audioservice.AudioServiceActivity() {
    private val channelName = "arch.player/library"
    private val sessionChannelName = "arch.player/session"
    private val updaterChannelName = "arch.player/updater"

    // Latest VIEW intent data (deep links). singleTop delivers
    // re-taps to onNewIntent; Dart pulls via pendingDeepLink
    // (pull, not push: no race with engine attach).
    @Volatile private var pendingLink: String? = null

    // MediaStore scans and bitmap decodes NEVER run on the main thread.
    // That was the ANR: seconds of main-thread work while scrolling.
    private val io = java.util.concurrent.Executors.newCachedThreadPool()

    // Write consent (API 30+): MediaStore returns an IntentSender the
    // user must approve. This is the app's FIRST activity-result path -
    // the session-grant flow dodges one with a deep link, but there is
    // no deep link for write access.
    //
    // startIntentSenderForResult + onActivityResult, NOT
    // registerForActivityResult: the latter is unresolved on this
    // project's androidx.activity version (verified by compiling).
    private val consentRequestCode = 4711
    private var pendingConsent: MethodChannel.Result? = null
    private val manageMediaRequestCode = 4712
    private var pendingManageUris: List<Uri>? = null

    // One-time media-management upgrade (API 31+): a single grant
    // silences every future per-file write dialog. canManageMedia is
    // a silent check, so an upgrade already granted (or a past denial
    // recorded below) never shows UI again. Asked once ever; denial
    // falls back to the per-file flow, unchanged.
    private fun manageMediaSettled(): Boolean = runCatching {
        if (Build.VERSION.SDK_INT >= 31 &&
            MediaStore.canManageMedia(this)
        ) {
            return true
        }
        getSharedPreferences("arch", MODE_PRIVATE)
            .getBoolean("manage_media_asked", false)
    }.getOrDefault(true)

    private fun markManageMediaAsked() = runCatching {
        getSharedPreferences("arch", MODE_PRIVATE).edit()
            .putBoolean("manage_media_asked", true).apply()
    }

    // Playback channel at HIGH importance, created BEFORE audio_service
    // posts anything: first creation wins, and the package default is
    // LOW (invisible icon, buried shade, skipped carousels). The old
    // LOW channel is deleted so no stale lock follows the user.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        harvestIntent(intent)
        if (Build.VERSION.SDK_INT >= 26) {
            try {
                val manager = getSystemService(NotificationManager::class.java)
                // Fresh channel id: deleting + recreating the SAME id
                // restores its old sound (undelete keeps prior config),
                // so silence needs an id the system has never seen.
                // A user-disabled channel is still always respected.
                val existing =
                    manager.getNotificationChannel("com.archstudios.arch_player.media")
                if (existing != null &&
                    existing.importance == NotificationManager.IMPORTANCE_NONE
                ) {
                    android.util.Log.d("ArchPlayer", "media channel user-disabled, respecting")
                } else {
                    manager.deleteNotificationChannel("com.archstudios.arch_player.media")
                    manager.createNotificationChannel(
                        NotificationChannel(
                            "com.archstudios.arch_player.media",
                            "Arch Player",
                            NotificationManager.IMPORTANCE_HIGH,
                        ).apply {
                            description = "Playback controls"
                            setShowBadge(false)
                            // Silent by design: audio_service re-posts on
                            // every state/art update, and a pinging player
                            // is a broken player. Visibility without noise.
                            setSound(null, null)
                            enableVibration(false)
                        },
                    )
                    android.util.Log.d("ArchPlayer", "media channel ensured silent at HIGH")
                }
                manager.deleteNotificationChannel("com.archstudios.arch_player.playback")
                manager.deleteNotificationChannel("com.archstudios.arch_player.channel")
            } catch (e: Exception) {
                android.util.Log.d("ArchPlayer", "playback channel setup failed: $e")
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        harvestIntent(intent)
    }

    private fun harvestIntent(intent: android.content.Intent?) {
        val data = intent?.data?.toString() ?: return
        // Only session-grant callbacks are stashed; everything
        // else (launcher MAIN, media buttons) is ignored.
        if (intent.action == android.content.Intent.ACTION_VIEW &&
            data.startsWith("spotiflac://session-grant")
        ) {
            pendingLink = data
            android.util.Log.d("ArchPlayer", "session grant link stashed")
        }
    }

    /// Consent result for requestWriteAccess. Only our own request code
    /// is consumed; every other result keeps flowing to super (plugins
    /// rely on that path).
    @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ) {
        if (requestCode == consentRequestCode) {
            val pending = pendingConsent
            pendingConsent = null
            pending?.success(resultCode == Activity.RESULT_OK)
            return
        }
        if (requestCode == manageMediaRequestCode) {
            // Upgrade answered (granted or not): asked once ever, then
            // run the pending per-file request — silent from here on
            // when granted, its own dialog when denied.
            val uris = pendingManageUris
            val pending = pendingConsent
            pendingManageUris = null
            pendingConsent = null
            if (uris != null && pending != null) {
                launchWriteRequest(uris, pending)
            } else {
                pending?.success(false)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "querySongs" -> io.execute {
                        android.util.Log.d("ArchLib", "querySongs: start")
                        val out = querySongs()
                        android.util.Log.d("ArchLib", "querySongs: done (${out.size})")
                        result.success(out)
                    }
                    "loadArt" -> {
                        val albumId = (call.argument<Number>("albumId")?.toLong()) ?: 0L
                        val targetPx = (call.argument<Number>("targetPx")?.toInt()) ?: 384
                        io.execute { result.success(loadArt(albumId, targetPx.coerceIn(96, 2048))) }
                    }
                    "suggestFolders" -> io.execute { result.success(suggestFolders()) }
                    "scanFile" -> {
                        val path = call.argument<String>("path").orEmpty()
                        if (path.isEmpty()) {
                            result.success(false)
                        } else {
                            io.execute {
                                // Fire-and-forget by design: the scan
                                // lands in MediaStore on its own time;
                                // Dart re-queries after a short delay.
                                val ok = runCatching {
                                    android.media.MediaScannerConnection.scanFile(
                                        this, arrayOf(path), null, null)
                                }.isSuccess
                                result.success(ok)
                            }
                        }
                    }
                    // Publish a staged pull into shared Music via
                    // MediaStore (own insert: no permission needed on
                    // 29+). Returns the content URI string, or null.
                    // App-specific dirs are invisible to MediaStore, so
                    // pulls MUST land here to join the Library.
                    "publishAudio" -> {
                        val src = call.argument<String>("srcPath").orEmpty()
                        val name = call.argument<String>("displayName").orEmpty()
                        val mime = call.argument<String>("mimeType").orEmpty()
                        val rel = call.argument<String>("relativePath").orEmpty()
                        if (src.isEmpty() || name.isEmpty()) {
                            result.success(null)
                        } else {
                            io.execute {
                                result.success(publishAudio(src, name, mime, rel))
                            }
                        }
                    }
                    // Remove a published file. Our own inserts need no
                    // permission; a row we do not own throws, which Dart
                    // answers with requestWriteAccess then retries.
                    "deleteAudio" -> {
                        val uri = call.argument<String>("uri").orEmpty()
                        val path = call.argument<String>("path").orEmpty()
                        if (uri.isEmpty() && path.isEmpty()) {
                            result.success(false)
                        } else {
                            io.execute { result.success(deleteAudio(uri, path)) }
                        }
                    }
                    // Swap a re-tagged temp copy in over an existing row.
                    // MediaStore cannot rewrite tags, so the tagger wrote
                    // a new file and this replaces the bytes in place.
                    "retagAudio" -> {
                        val uri = call.argument<String>("uri").orEmpty()
                        val src = call.argument<String>("srcPath").orEmpty()
                        val path = call.argument<String>("path").orEmpty()
                        if (uri.isEmpty() || src.isEmpty()) {
                            result.success(false)
                        } else {
                            io.execute {
                                result.success(retagAudio(uri, src, path))
                            }
                        }
                    }
                    // Ask the OS for write access to specific items
                    // (API 30+). True = granted. One prompt can cover
                    // several items, so a batch asks once.
                    "requestWriteAccess" -> {
                        val uris = call.argument<List<String>>("uris").orEmpty()
                        if (Build.VERSION.SDK_INT < 30 || uris.isEmpty()) {
                            result.success(false)
                        } else {
                            requestWriteAccess(uris, result)
                        }
                    }
                    "setKeepAwake" -> {
                        val keep = (call.argument<Boolean>("keep") ?: false)
                        runOnUiThread {
                            if (keep) {
                                window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            } else {
                                window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                            }
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        // Updater channel: hand the downloaded APK to the system
        // installer. No plugin: the download rides Dart http with
        // progress, this fires the VIEW intent through FileProvider.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updaterChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(
                        call.argument<String>("path").orEmpty(), result)
                    else -> result.notImplemented()
                }
            }
        // Session channel: deep-link pull + system-browser fallback.
        // The in-app WebView is the primary verify path; these two
        // calls exist so a challenge can never strand the user.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, sessionChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pendingDeepLink" -> {
                        val link = pendingLink
                        pendingLink = null
                        result.success(link)
                    }
                    "openBrowser" -> {
                        val url = call.argument<String>("url").orEmpty()
                        if (url.isEmpty()) {
                            result.success(false)
                        } else {
                            val ok = runCatching {
                                startActivity(android.content.Intent(
                                    android.content.Intent.ACTION_VIEW,
                                    android.net.Uri.parse(url),
                                ).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
                            }.isSuccess
                            result.success(ok)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun querySongs(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.DATA,
            MediaStore.Audio.Media.DATE_ADDED,
            MediaStore.Audio.Media.YEAR,
        )
        val selection = "${MediaStore.Audio.Media.IS_MUSIC} != 0"
        runCatching {
            contentResolver.query(
                collection, projection, selection, null,
                "${MediaStore.Audio.Media.TITLE} ASC",
            )?.use { c ->
                val idCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                val titleCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
                val artistCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
                val albumCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
                val albumIdCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
                val durCol = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
                val dataCol = c.getColumnIndex(MediaStore.Audio.Media.DATA)
                val addedCol = c.getColumnIndex(MediaStore.Audio.Media.DATE_ADDED)
                val yearCol = c.getColumnIndex(MediaStore.Audio.Media.YEAR)
                while (c.moveToNext()) {
                    val id = c.getLong(idCol)
                    val data = if (dataCol >= 0) c.getString(dataCol).orEmpty() else ""
                    val file = data.substringAfterLast('/', "")
                    val folder = data.removeSuffix("/$file").substringAfterLast('/').ifEmpty { "Unknown folder" }
                    out.add(
                        mapOf(
                            "id" to id,
                            "uri" to ContentUris.withAppendedId(collection, id).toString(),
                            "title" to (c.getString(titleCol) ?: "Unknown title"),
                            "artist" to (c.getString(artistCol) ?: "Unknown artist"),
                            "album" to (c.getString(albumCol) ?: "Unknown album"),
                            "albumId" to c.getLong(albumIdCol),
                            "durationMs" to c.getLong(durCol),
                            "folder" to folder,
                            "path" to data,
                            "addedSecs" to (if (addedCol >= 0) c.getLong(addedCol) else 0L),
                            "year" to (if (yearCol >= 0) c.getInt(yearCol) else 0),
                        ),
                    )
                }
            }
        }
        return out
    }

    /// Sized artwork: decode near the requested bucket, scale down
    /// preserving aspect (never upscale, never squash square), JPEG q90.
    /// 256px-for-everything was the blur; this is the fix.
    private fun loadArt(albumId: Long, targetPx: Int): ByteArray? {
        if (albumId <= 0) return null
        return runCatching {
            val uri = ContentUris.withAppendedId(
                android.net.Uri.parse("content://media/external/audio/albumart"),
                albumId,
            )
            contentResolver.openInputStream(uri)?.use { input ->
                val bytes = input.readBytes()
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
                val sample = sampleSize(bounds.outWidth, bounds.outHeight, targetPx)
                val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
                val bmp = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
                    ?: return null
                // Downscale only, aspect-safe. Small sources ship as-is:
                // upscaling natively would just be expensive blur.
                val scale = minOf(1f, targetPx / maxOf(bmp.width, bmp.height).toFloat())
                val out = if (scale < 1f) {
                    Bitmap.createScaledBitmap(
                        bmp, (bmp.width * scale).toInt(), (bmp.height * scale).toInt(), true)
                } else {
                    bmp
                }
                val stream = ByteArrayOutputStream()
                out.compress(Bitmap.CompressFormat.JPEG, 90, stream)
                stream.toByteArray()
            }
        }.getOrNull()
    }

    private fun sampleSize(w: Int, h: Int, target: Int): Int {
        var s = 1
        while (w / (s * 2) >= target && h / (s * 2) >= target) s *= 2
        return s
    }

    /// Delete one published file. Our own MediaStore inserts need no
    /// permission; a row we do not own throws
    /// RecoverableSecurityException, which we swallow to `false` so Dart
    /// can ask for consent and retry. Never throws.
    private fun deleteAudio(uri: String, path: String): Boolean {
        if (uri.isNotEmpty()) {
            val removed = runCatching {
                contentResolver.delete(Uri.parse(uri), null, null) > 0
            }.getOrDefault(false)
            if (removed) return true
        }
        if (path.isNotEmpty()) {
            return runCatching {
                val f = java.io.File(path)
                if (f.isFile) f.delete() else false
            }.getOrDefault(false)
        }
        return false
    }

    /// Replace an existing row's bytes with a freshly tagged temp file.
    /// The tagger copies audio (-c copy), so this is a plain stream copy
    /// plus a scan nudge so MediaStore re-reads the new tags.
    private fun retagAudio(uri: String, srcPath: String, path: String): Boolean {
        val src = java.io.File(srcPath)
        if (!src.isFile || src.length() <= 0L) return false
        val ok = runCatching {
            contentResolver.openOutputStream(Uri.parse(uri), "wt")?.use { out ->
                src.inputStream().use { input -> input.copyTo(out) }
            } != null
        }.getOrDefault(false)
        if (!ok) return false
        if (path.isNotEmpty()) {
            // Wait for the rescan to land: Dart invalidates the library
            // the moment this returns, and a fire-and-forget scan would
            // lose that race every time — the hero would keep showing
            // the pre-fix row until the next launch. Runs on the io
            // executor, never the main thread. Timeout keeps a dead
            // scanner from wedging the retag: bytes already landed.
            runCatching {
                val done = java.util.concurrent.CountDownLatch(1)
                android.media.MediaScannerConnection.scanFile(
                    this, arrayOf(path), null
                ) { _, _ -> done.countDown() }
                done.await(8, java.util.concurrent.TimeUnit.SECONDS)
            }
        }
        return true
    }

    /// MediaStore write consent for items we do not own. Exactly one
    /// request may be in flight: a second would strand the first
    /// caller's result. On API 31+ the first consent ever is the
    /// manage-media upgrade instead of a per-file dialog — one grant,
    /// then every later write request auto-approves silently.
    private fun requestWriteAccess(
        uris: List<String>,
        result: MethodChannel.Result,
    ) {
        if (pendingConsent != null) {
            result.success(false)
            return
        }
        val list = uris.map { Uri.parse(it) }
        if (Build.VERSION.SDK_INT >= 31 && !manageMediaSettled()) {
            runCatching {
                val intent = android.content.Intent(
                    android.provider.Settings.ACTION_REQUEST_MANAGE_MEDIA,
                )
                pendingConsent = result
                pendingManageUris = list
                markManageMediaAsked()
                startActivityForResult(intent, manageMediaRequestCode)
            }.onFailure {
                android.util.Log.w("ArchLib", "manage media failed: ${it.message}")
                pendingConsent = null
                pendingManageUris = null
                launchWriteRequest(list, result)
            }
            return
        }
        launchWriteRequest(list, result)
    }

    /// The per-file write request, launched directly or chained after
    /// the manage-media upgrade (silent when the upgrade was granted).
    private fun launchWriteRequest(
        list: List<Uri>,
        result: MethodChannel.Result,
    ) {
        runCatching {
            val pi = MediaStore.createWriteRequest(contentResolver, list)
            pendingConsent = result
            startIntentSenderForResult(
                pi.intentSender,
                consentRequestCode,
                null,
                0,
                0,
                0,
            )
        }.onFailure {
            android.util.Log.w("ArchLib", "write consent failed: ${it.message}")
            pendingConsent = null
            result.success(false)
        }
    }

    /// Publish staged bytes into shared Music via MediaStore
    /// (29+). Own inserts need no permission; the entry is indexed
    /// immediately on unpend. [relativePath] selects the folder
    /// (e.g. "Music/Needle/Songs/X/"); anything outside shared
    /// Music or blank falls back to "Music/Arch Player/".
    /// Pre-29 falls back to a direct copy into public Music (needs
    /// write permission, best-effort). Returns the content URI
    /// string or null.
    private fun publishAudio(src: String, name: String, mime: String, relativePath: String = ""): String? {
        return runCatching {
            val srcFile = java.io.File(src)
            if (!srcFile.isFile || srcFile.length() <= 0) return null
            val mimeType = mime.ifEmpty {
                when (name.substringAfterLast('.', "").lowercase()) {
                    "m4a", "mp4" -> "audio/mp4"
                    "flac" -> "audio/flac"
                    "mp3" -> "audio/mpeg"
                    "ogg", "opus" -> "audio/ogg"
                    "wav" -> "audio/wav"
                    else -> "audio/mpeg"
                }
            }
            if (Build.VERSION.SDK_INT >= 29) {
                // Clamp to shared Music: no escapes, no blank, always
                // trailing slash. Grandfathered pulls keep landing in
                // the old folder when nothing is passed.
                var rel = relativePath.trim().replace('\\', '/')
                if (!rel.startsWith("Music/")) rel = "Music/Arch Player/"
                if (!rel.endsWith("/")) rel += "/"
                if (rel.contains("..")) rel = "Music/Arch Player/"
                val values = android.content.ContentValues().apply {
                    put(MediaStore.Audio.Media.DISPLAY_NAME, name)
                    put(MediaStore.Audio.Media.MIME_TYPE, mimeType)
                    put(
                        MediaStore.Audio.Media.RELATIVE_PATH,
                        rel,
                    )
                    put(MediaStore.Audio.Media.IS_PENDING, 1)
                }
                val collection = MediaStore.Audio.Media.getContentUri(
                    MediaStore.VOLUME_EXTERNAL,
                )
                val uri = contentResolver.insert(collection, values)
                    ?: return null
                try {
                    contentResolver.openOutputStream(uri)?.use { out ->
                        srcFile.inputStream().use { input ->
                            input.copyTo(out)
                        }
                    } ?: return run {
                        contentResolver.delete(uri, null, null)
                        null
                    }
                } catch (e: Exception) {
                    contentResolver.delete(uri, null, null)
                    throw e
                }
                val done = android.content.ContentValues().apply {
                    put(MediaStore.Audio.Media.IS_PENDING, 0)
                }
                contentResolver.update(uri, done, null, null)
                uri.toString()
            } else {
                val music = android.os.Environment.getExternalStoragePublicDirectory(
                    android.os.Environment.DIRECTORY_MUSIC,
                )
                val dir = java.io.File(music, "Arch Player")
                dir.mkdirs()
                val dest = java.io.File(dir, name)
                srcFile.copyTo(dest, overwrite = true)
                android.media.MediaScannerConnection.scanFile(
                    this, arrayOf(dest.absolutePath), null, null)
                android.net.Uri.fromFile(dest).toString()
            }
        }.getOrNull()
    }

    /// Hand a downloaded APK to the system installer via FileProvider.
    /// False = nothing to hand over or no activity to take it; the
    /// caller falls back to the release page. Never throws.
    private fun installApk(path: String, result: MethodChannel.Result) {
        if (path.isEmpty() || !java.io.File(path).isFile) {
            result.success(false)
            return
        }
        val ok = runCatching {
            val uri = androidx.core.content.FileProvider.getUriForFile(
                this, "${packageName}.fileProvider", java.io.File(path))
            val intent = android.content.Intent(
                android.content.Intent.ACTION_VIEW,
            ).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            startActivity(intent)
            true
        }.getOrDefault(false)
        android.util.Log.d("ArchUpdater", "install intent fired: $ok")
        result.success(ok)
    }

    /** Common music homes that actually exist, for first-run suggestions. */
    private fun suggestFolders(): List<String> {
        val roots = mutableListOf<java.io.File>()
        getExternalFilesDir(null)?.let { roots.add(it) }
        android.os.Environment.getExternalStorageDirectory()?.let { roots.add(it) }
        val names = listOf("Music", "Download", "Audio", "MP3", "Songs")
        val out = mutableListOf<String>()
        for (root in roots) {
            for (name in names) {
                val dir = java.io.File(root, name)
                if (dir.isDirectory) out.add(dir.absolutePath)
            }
        }
        return out.distinct()
    }
}
