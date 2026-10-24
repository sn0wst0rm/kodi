iOS native PiP host checks
=========================
Run ./run-host-tests.sh on macOS with Xcode command-line tools selected.

PlaybackPolicy covers duplicate interruption notifications, user-paused playback,
explicit playback intent changes, OS veto, changed stream and exactly-once resume.
NativeVideoCompositor exercises NV12 and P010, video/full ranges, SDR/PQ/HLG,
subtitle placement, black levels, attachment propagation, pool reuse and invalid
input. The second run scales synthetic 4K video to a 960x540 PiP surface and
prints host elapsed time. It is not an iPhone power or performance measurement.

The video is still decoded by VideoToolbox. When PiP has no subtitles, original
hardware-decoded surfaces go directly to AVFoundation. Visible PiP subtitles use
bounded YUV scaling and glyph blending on the CPU because background apps cannot
submit arbitrary Metal/OpenGL work. P010 and transfer metadata remain intact.

Device tests still required before considering the preview verified:
- Manual PiP from the folded panel; PiP stop/restore and Back navigation.
- Automatic PiP with Home, restore, close, pause/play and seek controls.
- Notification Center, Control Center and app switcher while playing and paused.
- Real phone/Siri interruption and headphone removal; no unintended auto-resume.
- Long playback, seek, buffering, channel changes and app backgrounding in PiP.
- MPD/InputStream Adaptive, HLS, 4K MKV, subtitles (ASS/text/image), SDR/PQ/HLG.
- Open/closed/folded Duo layout, audio sync, temperature and resource usage.

Limitations: native path requires an actual VideoToolbox-decoded buffer (iOS17+).
Unsupported hardware codecs and interlaced/software fallback do not gain PiP.
Native GL capture is unsupported. Dolby Vision profile/enhancement-layer output
and PiP-specific dynamic metadata behaviour have not been verified.

VideoFormatCache verifies that format reuse preserves image identity (no pixel
copy), invalidates for resize/SDR/PQ/HLG and mastering metadata changes, and resets
between sessions. Its microbenchmark isolates format-description allocation and
matching; it does not include the native renderer's IPC or infer battery savings.
