package com.archstudios.arch_player

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentUris
import android.graphics.Bitmap
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : com.ryanheise.audioservice.AudioServiceActivity() {
    private val channelName = "arch.player/library"

    // MediaStore scans and bitmap decodes NEVER run on the main thread.
    // That was the ANR: seconds of main-thread work while scrolling.
    private val io = java.util.concurrent.Executors.newCachedThreadPool()

    // Playback channel at HIGH importance, created BEFORE audio_service
    // posts anything: first creation wins, and the package default is
    // LOW (invisible icon, buried shade, skipped carousels). The old
    // LOW channel is deleted so no stale lock follows the user.
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
