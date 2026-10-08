# Needle — Download Providers Plan

Status: planned, not built. Engine parity (scan + playback + library) comes first.
Name locked: **Needle**. Pill entry reserved; no code yet.

## Vision

One-stop shop: music gets into the app without a second app. Needle is a
**provider system**, not a downloader for one site — sources plug in as
community-built adapters so nobody needs multiple apps. Modeled on
SpotiFLAC's extension registry and Namida's download engine (both studied,
see References).

## The split (the whole idea)

- **Core (built once, source-agnostic):** queue, transfer, filenames,
  folders, tags, storage, Needle UI. Contributors never touch this.
- **Providers (one per source, community-built):** metadata + stream URLs
  behind a manifest contract. Thin adapters, not rewrites.

Nobody reinvents download logic per source. The hard parts are built once.

## Core engine (steal these shapes)

From Namida (`lib/youtube/`, `lib/controller/files_download_manager.dart`):

1. **Parallel slot queue** — user-set max parallel downloads, dedupe by
   filename key, skip-check before start, per-task futures.
   (`parallel_downloads_controller.dart`, ~80 lines)
2. **Filename sanitizer** — illegal chars to `_`, per-platform path-length
   caps, `name (2).ext` collision suffixes, stable task keys.
   (`download_task_base.dart`)
3. **Group folders** — every download lands in a named group folder;
   groups double as library folders. (`DownloadTaskGroupName`)
4. **Ongoing vs. finished lists** — sorted binary insert, filter without
   re-sorting. (`youtube_ongoing_finished_downloads.dart`)
5. **Tag-first sheet** — editable tags + filename template + folder picker
   *before* download; tags written post-download. Full sheet is ambition;
   paste-and-go is the acceptable v1.
6. **Retry/resume/checkpoint** — attempts, backoff, validated resume,
   persistent checkpoints (SpotiFLAC manifest declares these; our engine
   enforces them).

Deliberately skipped: ffmpeg full binary (53MB vendored AAR in Namida).
Tag with taglib-grade tooling; keep the APK lean unless conversion proves
necessary.

## Provider contract (interface to design with first built-in source)

Each provider = `manifest.json` + adapter code, modeled on SpotiFLAC's:

```jsonc
{
  "id": "example",
  "displayName": "Example",
  "version": "1.0.0",
  "type": ["metadata_provider", "download_provider"],
  "minAppVersion": "0.2.0",
  "permissions": { "network": ["example.com"], "storage": true },
  "qualityOptions": [
    { "id": "LOSSLESS", "label": "Lossless", "kind": "lossless" }
  ],
  "capabilities": {
    "downloadTransfer": {
      "maxAttempts": 4, "resumePolicy": "validated",
      "maxParallelSegments": 4, "maxConcurrentDownloads": 2
    }
  },
  "settings": [ /* user-facing config schema: tokens, quality default */ ],
  "urlHandler": { "enabled": true, "patterns": ["example.com"] }
}
```

Adapter duties: search, resolve, stream-URL. Nothing else — transfer,
retry, tags, and storage belong to core. Registry entry pins `sha256` +
`min_app_version`; submissions via PR with per-provider tests.

## Phases

1. **Core + ONE built-in provider.** Proves the contract end to end:
   search → sheet → queue → tagged file in library. No registry yet.
2. **Open the interface.** Document the manifest + adapter contract,
   registry file, submission process. Second source built against the
   docs (not by the docs' author) to prove they work.
3. **Registry.** Versioned directory, update checks, disable-broken-source
   path. Community owns new sources from here.

## Costs and risks (stated plainly)

- **Sources break** when sites change — the chronic tax. Answered with
  registry versioning + per-provider tests + min versions, mostly borne
  by contributors. Real maintenance, not free.
- **Gray areas:** YouTube-sourced downloading violates YouTube's ToS;
  Namida/SpotiFLAC ship it anyway. Source choice for the built-in
  provider is a deliberate decision, not a default.
- **Server-assisted auth:** some sources (cf. SpotiFLAC's session helper
  backend) need more than a client adapter. Decide per source; default
  to pure-client.
- **JS runtime + sandbox:** adapters run in an embedded JS runtime with
  the manifest's domain allowlist actually enforced. Design work, not free.
- **Fork-everything is not the plan:** Namida forks just_audio,
  audio_service, on_audio_query… we use pub versions + thin own channels
  to avoid solo-dev maintenance burden.

## Open decisions (do not invent)

- [ ] Built-in source: YouTube-client vs. clean sources vs. paste-link URLs?
- [ ] v1 sheet scope: full tag-editing ambition vs. dead-simple paste-and-go?
- [ ] JS runtime choice for adapters.
- [ ] Stance on server-assisted auth helpers.

## References

- SpotiFLAC-Mobile `MornyeSelectionPill` + `liquid_glass_easy` (glass study)
- `spotiflacapp/SpotiFLAC-Extension`: `registry.json`, `sources/*/manifest.json`
  (provider contract template), `tests/` (per-provider test pattern)
- Namida `lib/youtube/class/download_task_base.dart`,
  `lib/youtube/controller/parallel_downloads_controller.dart`,
  `lib/youtube/controller/youtube_ongoing_finished_downloads.dart`,
  `lib/youtube/functions/video_download_options.dart` (engine shapes)
