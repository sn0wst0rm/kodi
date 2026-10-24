Kodi 23 / iPhone Duo Canary
==========================

Branches
--------
Stable: https://github.com/sn0wst0rm/kodi/tree/feature/iphone-duo
Canary: https://github.com/sn0wst0rm/kodi/tree/feature/iphone-duo-canary

This branch starts directly at upstream master
0658cd06e07d1b4b23c4155404c9006a4ccf0951 (23.0-ALPHA1, 2026-10-24).
The stable branch is based on Kodi 21.3. This is an experimental Kodi 23
port; install it with a distinct bundle identifier to keep both versions.

Features carried over
---------------------
* Scene-based resizing and full-screen internal/external displays, both
  landscape directions, confirmed hinge posture, and transformed touch input.
* Lower folded controls: seek slider, elapsed/total/remaining time, -10/+10,
  playback/stop, Back, PiP, video/audio/subtitle settings and information.
  Lower settings expose adaptive Auto/manual quality, HDR and eligible tempo.
* Native SDR/HDR presentation, PQ/HLG 10-bit surfaces, HDR-to-SDR pixel transfer
  without video re-encoding, manual/automatic PiP, and subtitle composition.
* Playback continues through transient focus loss; genuine audio interruptions,
  route changes and explicit pauses use the existing Duo interruption policy.
* Bounded WS-Discovery/audio waits, native layer/format reuse, GLES GUI skipping
  and occlusion, AArch64 audio interpolation, and Apple CommonCrypto AES.

Adaptation to upstream
----------------------
* Use upstream VideoToolbox eligibility for progressive live streams.
  Interlaced/unsupported inputs retain upstream fallback behavior.
* RendererIOS implements the new VideoBypassesFramebuffer contract. Kodi's new
  capture service remains intact; native video capture is explicitly unsupported
  through the base renderer's default implementation.
* Keep master's PrepareOverlays, visible-overlay tracking, libass API and HDR
  PGS palette conversion. PiP uses a separate CPU subtitle rasterization pass
  while the foreground GL pass is suspended. HDR PGS colors are converted to
  SDR before entering the existing native subtitle compositor.
* Omit the superseded HDR additions to the GLES renderer. On supported iOS,
  RendererIOS owns SDR/HDR output; the older fallback keeps upstream GLES code.
* FFmpeg 9.0.2 still has a scalar float linear resampler. Retarget the NEON patch
  to that version, including its unsigned accumulator type, without replacing
  upstream interpolation, phase accounting or other SIMD implementations.
* InputStream Adaptive uses upstream Piers 22.3.23 (the repository's current
  default branch). Auto/pinned qualities use its unique stream IDs, playable
  representation filtering, stream limit and new segment queue. The
  companion patches are reproducibly archived under tools/duo.
* Preserve fractional segment durations when choosing the live start in
  InputStream Adaptive. Durations accumulate in timeline ticks before
  rounding, so fractional segments do not accumulate truncation errors.
* Resampled audio stays muted until its initial clock correction completes.
  Releasing samples before inserting startup silence can cause an audible
  interruption on live streams.
* Existing SDK fixes for old libpng, zlib, HarfBuzz and libffi are not copied
  onto updated dependencies. Native Python needs dup3/pipe2 probes disabled
  with SDK 27 while targeting older macOS. The iOS application targets 15.0;
  native video requires iOS 17+, hinge controls require iOS 27.1 and hardware.

Companion source reconstruction
-------------------------------
Exact bases and patch SHA-256s: tools/duo/source-manifest.json.
With a configured Git identity, from this source checkout:

  python3 tools/duo/prepare-inputstream-adaptive.py /path/to/new/adaptive-source

Use --repository /path/to/existing/clone for offline reconstruction. The helper
checks the patch hashes and final source tree, so differing git-am commit dates
are harmless. No personal credentials, provisioning profiles or signed IPAs
are included.

Build
-----
Use docs/README.iOS.md and tools/depends/README.md for prerequisites. Use fresh
build and dependency directories: the 21.3 dependency prefix has incompatible
FFmpeg/Python versions. Example for the SDK used for this port:

  cd tools/depends
  ./bootstrap
  ./configure --host=aarch64-apple-darwin --with-platform=ios --with-sdk=27.1 \
    --prefix=/path/to/canary/depends --with-tarballs=/path/to/tarballs \
    --disable-ccache --enable-debug=no
  make -j8
  cd ../..
  make -C tools/depends/target/cmakebuildsys BUILD_DIR=/path/to/canary/build \
    CMAKE_EXTRA_ARGUMENTS='-DENABLE_XCODE_ADDONBUILD=OFF -DENABLE_TESTING=OFF'
  cd /path/to/canary/build
  CMAKE_BUILD_PARALLEL_LEVEL=8 xcodebuild -project kodi.xcodeproj -configuration Release -target kodi \
    -jobs 8 CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=15.0

Build the reconstructed add-on against the newly generated Kodi SDK, never the
21.3 SDK. Enable ENABLE_INTERNAL_BENTO4 and ENABLE_KODI_DUO_QUALITY, disable
BUILD_TESTING for the cross build, and use the new iOS Toolchain.cmake and
Release configuration. Provide an arm64 iOS pugixml 1.16 prefix and nlohmann-json 3.12.0
headers. Bento4 1.6.0-641-6-Piers is fetched and patched automatically. Install
the complete new add-on bundle; do not reuse a 21.x add-on dylib with Kodi 23.
Use tools/duo/stage-ios-addon.py with the add-on ID, source directory, build
directory and a new destination directory. It includes generated resources,
especially InputStream Adaptive's settings.xml, which is required to initialize
playback. Copying only the source resources and generated addon.xml is incomplete.
For side-by-side testing, sign a staged copy with a distinct bundle identifier
and display name (for example, org.xbmc.kodi.canary / Kodi Canary).
Give its URL schemes distinct names as well. Copy user data into the new app
container only; keep the stable container intact. Private settings/SMB access
information and third-party Python add-ons are not part of this repository.

Validation
----------
Host checks:

  sh xbmc/platform/darwin/ios/tests/run-host-tests.sh
  python3 tools/depends/target/ffmpeg/tests/check-linear-neon.py <patched FFmpeg 9>

In reconstructed InputStream Adaptive:

  bash tools/tests/test_apple_aes.sh <patched Bento4> <output>
  SANITIZE=1 bash tools/tests/test_apple_aes.sh <patched Bento4> <asan-output>

Host tests cover video-format caching, interruption policy, HDR headroom,
HDR-to-SDR conversion, subtitle composition and SIMD audio-resampler accuracy.
The AES tests cover standard vectors, fragmented input, counter carry, seeks,
and in-place processing. The adaptive live-start regression uses synthetic
DASH timelines with whole-second, fractional and subsecond segment durations.
These fixtures are test inputs, not runtime playback presets.

On-device validation should include fold/open/rotate/touch, video settings,
adaptive quality, HDR toggling, focus loss, PiP/subtitles, seeking, tempo,
MPD/HLS playback and sustained CPU/energy measurements. Host tests alone do
not establish playback correctness or power consumption on an iPhone.

OpenGL still draws the Kodi UI; this is not a Metal port. Native video is not
included in Kodi's internal capture. Dolby Vision dynamic metadata/enhancement
layers are not guaranteed by HDR10 output. UIKit system chrome can orient
independently of the landscape Kodi canvas. Python/add-on compatibility must be
checked against this newer Kodi branch before migrating a user profile.
