// Copyright (C) 2026 Skrol-C.
// This file is part of Arch Player, which is free software: you can
// redistribute it and/or modify it under the terms of the GNU General
// Public License as published by the Free Software Foundation, either
// version 3 of the License, or (at your option) any later version.
// See the repository LICENSE file for the full text.
//
// Stream tickets via NewPipeExtractor (TeamNewPipe, GPLv3):
// https://github.com/TeamNewPipe/NewPipeExtractor
// Pinned version: v0.26.5 (see android/app/build.gradle.kts). This
// bridge links the extractor library and maps its streams to plain
// channel maps; no extractor source is copied into this file.

package com.archstudios.arch_player

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import okhttp3.OkHttpClient
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.NewPipe
import org.schabi.newpipe.extractor.ServiceList
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import org.schabi.newpipe.extractor.stream.AudioStream
import org.schabi.newpipe.extractor.stream.StreamInfo
import org.schabi.newpipe.extractor.stream.VideoStream
import java.io.IOException
import java.util.concurrent.Executor

/// Narrow ticket window over NewPipeExtractor: videoId in, a list of
/// stream maps out (url, itag, quality, videoOnly/audioOnly flags,
/// bitrate, codec, delivery, width/height). Playback, matching, the
/// quality UI, and the range proxy are untouched: they consume these
/// tickets exactly like home-grown InnerTube ones.
class ExtractorBridge(
    private val io: Executor,
    private val okHttp: OkHttpClient,
) {
    companion object {
        const val CHANNEL = "arch.player/extractor"

        @Volatile
        private var initialized = false

        @Synchronized
        private fun ensureInit(client: OkHttpClient) {
            if (!initialized) {
                NewPipe.init(ArchDownloader(client))
                initialized = true
            }
        }
    }

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStreams" -> {
                    val videoId = call.argument<String>("videoId").orEmpty()
                    if (videoId.isEmpty()) {
                        result.error("BAD_ARGS", "empty videoId", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        try {
                            ensureInit(okHttp)
                            val info = StreamInfo.getInfo(
                                ServiceList.YouTube,
                                "https://www.youtube.com/watch?v=$videoId",
                            )
                            val out = mutableListOf<Map<String, Any?>>()
                            for (s in info.videoStreams) {
                                val m = videoMap(s, videoOnly = false)
                                if ((m["url"] as String).isNotEmpty()) out.add(m)
                            }
                            for (s in info.videoOnlyStreams) {
                                val m = videoMap(s, videoOnly = true)
                                if ((m["url"] as String).isNotEmpty()) out.add(m)
                            }
                            for (s in info.audioStreams) {
                                val m = audioMap(s)
                                if ((m["url"] as String).isNotEmpty()) out.add(m)
                            }
                            result.success(out)
                        } catch (e: Exception) {
                            android.util.Log.d(
                                "ArchExtractor",
                                "getStreams failed: ${e.message}",
                            )
                            result.error("EXTRACT_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun videoMap(s: VideoStream, videoOnly: Boolean): Map<String, Any?> =
        mapOf(
            "url" to (if (s.isUrl) s.content else ""),
            "itag" to s.itag,
            "quality" to s.resolution,
            "videoOnly" to videoOnly,
            "audioOnly" to false,
            "bitrate" to s.bitrate,
            "codec" to s.codec,
            "delivery" to s.deliveryMethod.name,
            "width" to s.width,
            "height" to s.height,
        )

    private fun audioMap(s: AudioStream): Map<String, Any?> =
        mapOf(
            "url" to (if (s.isUrl) s.content else ""),
            "itag" to s.itag,
            "quality" to s.quality,
            "videoOnly" to false,
            "audioOnly" to true,
            "bitrate" to if (s.averageBitrate > 0) s.averageBitrate else s.bitrate,
            "codec" to s.codec,
            "delivery" to s.deliveryMethod.name,
            "width" to 0,
            "height" to 0,
        )

    /// OkHttp-backed extractor downloader, following the extractor's
    /// own quickstart recipe (adapted to Kotlin).
    private class ArchDownloader(private val client: OkHttpClient) : Downloader() {
        @Throws(IOException::class, ReCaptchaException::class)
        override fun execute(request: Request): Response {
            val data = request.dataToSend()
            var body: okhttp3.RequestBody? = null
            if (data != null) {
                body = data.toRequestBody(null)
            } else if (request.httpMethod() == "POST" ||
                request.httpMethod() == "PUT" ||
                request.httpMethod() == "PATCH"
            ) {
                body = ByteArray(0).toRequestBody(null)
            }
            val builder = okhttp3.Request.Builder()
                .method(request.httpMethod(), body)
                .url(request.url())
            for ((name, values) in request.headers()) {
                for (v in values) builder.addHeader(name, v)
            }
            client.newCall(builder.build()).execute().use { resp ->
                if (resp.code == 429) {
                    throw ReCaptchaException(
                        "reCaptcha Challenge requested",
                        request.url(),
                    )
                }
                val text = resp.body?.string()
                return Response(
                    resp.code,
                    resp.message,
                    resp.headers.toMultimap(),
                    text,
                    resp.request.url.toString(),
                )
            }
        }
    }
}
