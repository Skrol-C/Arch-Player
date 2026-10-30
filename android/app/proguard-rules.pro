# NewPipeExtractor ships Rhino (org.mozilla.javascript) which references
# java.beans APIs absent on Android. Warnings only — the classes are
# never loaded at runtime on our path. Silence, don't strip the engine.
-dontwarn java.beans.**
-dontwarn org.mozilla.javascript.**
-keep class org.mozilla.javascript.** { *; }
-keep class org.schabi.newpipe.extractor.** { *; }
