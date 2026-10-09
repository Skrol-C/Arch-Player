package com.archstudios.arch_player

import android.content.ContentUris
import android.graphics.Bitmap
import android.os.Build
import android.provider.MediaStore
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : com.ryanheise.audioservice.AudioServiceActivity() {
    private val channelName = "arch.player/library"

    // MediaStore scans and bitmap decodes NEVER run on the main thread.
    // That was the ANR: seconds of main-thread work while scrolling.
    private val io = java.util.concurrent.Executors.newCachedThreadPool()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "querySongs" -> io.execute { result.success(querySongs()) }
                    "loadArt" -> {
                        val albumId = (call.argument<Number>("albumId")?.toLong()) ?: 0L
                        io.execute { result.success(loadArt(albumId)) }
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
                        ),
                    )
                }
            }
        }
        return out
    }

    private fun loadArt(albumId: Long): ByteArray? {
        if (albumId <= 0) return null
        return runCatching {
            val uri = ContentUris.withAppendedId(
                android.net.Uri.parse("content://media/external/audio/albumart"),
                albumId,
            )
            contentResolver.openInputStream(uri)?.use { input ->
                val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
                val bytes = input.readBytes()
                android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
                val sample = sampleSize(bounds.outWidth, bounds.outHeight, 256)
                val opts = android.graphics.BitmapFactory.Options().apply { inSampleSize = sample }
                val bmp = android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts)
                    ?: return null
                val scaled = Bitmap.createScaledBitmap(bmp, 256, 256, true)
                val stream = ByteArrayOutputStream()
                scaled.compress(Bitmap.CompressFormat.JPEG, 80, stream)
                stream.toByteArray()
            }
        }.getOrNull()
    }

    private fun sampleSize(w: Int, h: Int, target: Int): Int {
        var s = 1
        while (w / (s * 2) >= target && h / (s * 2) >= target) s *= 2
        return s
    }
}
