Kodi 21.3 / iPhone Duo
=====================

This branch preserves the 23 Kodi commits used through the installed Release
build of 2026-10-24, plus the two companion InputStream Adaptive changes.
The later archival commit adds documentation, dependency patches and a source
manifest; it does not change the application code.

Source baseline
---------------
Kodi: 21.3-Omega, a3a448d26b8d560a65655dab2cd122994dc4e146.
Latest built Kodi: 12309b123621f5d6e6346503a62c717e7d2285d3.
InputStream Adaptive: 21.5.18-Omega, with local commits f40a47c and dfd2e46.
Exact refs, source trees and patch hashes: tools/duo/source-manifest.json.
The installed binary used the arm64 iPhoneOS 27.1 SDK, deployment target 15.0,
and Kodi's Release configuration. Native video presentation requires iOS 17+;
Duo hinge APIs require the matching SDK and device support.

Changes included
----------------
* Scene lifecycle and resizing for internal/external displays, immersive canvas,
  both landscape directions, and a landscape Kodi canvas inside portrait scenes.
  Tabletop mode requires confirmed hinge posture and a horizontal split region;
  rotating a flat device alone must not activate the lower controls.
* Folded upper Kodi view and lower native controls: scrubber, elapsed time and
  total/remaining toggle, exact -10/+10 seconds, pause/resume, stop, settings,
  subtitles, info, audio language, Back and PiP. Repeated dialog actions close
  the active dialog. UIKit converts touches through the view transform.
* Inline lower settings with Auto/pinned adaptive qualities, HDR toggle for HDR
  input, and 0.5x-2x playback tempo on eligible seekable, non-live content.
  Settings also opens Kodi's upper video settings dialog.
* Native AVFoundation PiP, both explicit and automatic on Home. Playback is not
  paused merely by transient loss of focus, such as Control/Notification Center.
  Real audio interruptions, route changes and explicit pauses remain distinct.
* Progressive live VideoToolbox decoding, native SDR/HDR video surfaces, 10-bit
  PQ/HLG metadata and display headroom handling. HDR-off uses VideoToolbox pixel
  transfer into explicit SDR buffers, not a video encode/decode cycle; the
  original frame remains available for HDR-on and switching while paused.
* Performance work: bounded WS-Discovery retries, waiting instead of spinning
  on paused empty audio queues, NEON audio interpolation, native video format
  reuse, avoiding redundant layer geometry/property writes, and skipping
  unnecessary GLES GUI invalidations while native video is being presented.
  The retained GL surface is occluded when no Kodi overlays are visible.
* Modern Apple SDK build fixes in the dependency recipes are included, including
  the FFmpeg resampler patch and its differential test.
* Companion InputStream Adaptive changes expose real manifest qualities and use
  CommonCrypto for Bento4 AES-CBC/CTR on Apple platforms. The internal Bento4
  dependency automatically applies the bundled Apple patch. Other platforms
  retain the original implementation.

Prepare companion sources
-------------------------
From this Kodi checkout, with Git user.name and user.email configured:

  python3 tools/duo/prepare-inputstream-adaptive.py /path/to/new/adaptive-source

This clones the official InputStream Adaptive repository, checks out the pinned
upstream commit and applies the two full Git patches. It checks patch SHA-256s,
the resulting Git tree and cleanliness. git am changes the committer identity
and date, so the reconstructed commit ID may differ; the source tree must match.
Use --repository /path/to/existing/clone for an offline reconstruction.

Build outline
-------------
Use docs/README.iOS.md and tools/depends/README.md for prerequisites and upstream
packaging details. The settings below record the build used for this branch;
replace /path/to/work with a writable directory outside the source checkout.

From tools/depends:

  ./bootstrap
  ./configure --host=aarch64-apple-darwin --with-platform=ios --with-sdk=27.1 \
    --prefix=/path/to/work/depends --with-tarballs=/path/to/work/tarballs \
    --disable-ccache
  make -j8

From the Kodi source root:

  make -C tools/depends/target/cmakebuildsys BUILD_DIR=/path/to/work/build \
    CMAKE_EXTRA_ARGUMENTS='-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DENABLE_XCODE_ADDONBUILD=OFF -DENABLE_TESTING=OFF'

From /path/to/work/build:

  xcodebuild -project kodi.xcodeproj -configuration Release -target kodi -jobs 8 \
    CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=15.0

The app is build/Release-iphoneos/Kodi.app relative to that build directory.
Reconfigure CMake after changing Info.plist.in. The dependency toolchain in the
recorded build is under depends/iphoneos27.1_arm64-target-debug/share; the
application itself was built in Release. This is not a claim that every
dependency was rebuilt with a new Release toolchain.

Build the reconstructed InputStream Adaptive separately against Kodi's generated
SDK and toolchain, using CMake settings:

  CMAKE_TOOLCHAIN_FILE=<depends target>/share/Toolchain.cmake
  Kodi_DIR=<Kodi build>/build/lib/kodi
  CMAKE_BUILD_TYPE=Release
  CMAKE_OSX_DEPLOYMENT_TARGET=15.0
  ENABLE_INTERNAL_BENTO4=ON
  ENABLE_KODI_DUO_QUALITY=ON
  BUILD_TESTING=OFF
  PUGIXML_INCLUDE_DIRS=<arm64 iOS pugixml prefix>/include
  PUGIXML_LIBRARIES=<arm64 iOS pugixml prefix>/lib/libpugixml.a

The recorded build used static pugixml 1.13 and internal Bento4
1.6.0-641-3-Omega. ENABLE_KODI_DUO_QUALITY is required for the lower panel's
Auto/manual quality selector and is intentionally opt-in for this Kodi fork.
Install/copy the complete InputStream Adaptive resource bundle into
Kodi.app/AppData/AppHome/addons/inputstream.adaptive, with the newly built
inputstream.adaptive.21.5.18.dylib. IPTV Simple 21.11.0 was also installed, with
no local source modifications. Missing standard add-on resources in the local
Xcode app were copied from the official Kodi 21.3 package while preserving
freshly built core add-ons. Device-installed Python add-ons/user settings are
not part of the application source.

Sign nested binaries/frameworks and the completed app with your own valid Apple
profile and matching bundle identifier, then package Payload/Kodi.app as an IPA.
The personal provisioning profile, private signing key, device logs and signed
IPA are not distributed here. The manifest's IPA hash identifies the local
installed artifact; rebuilding/signing does not produce identical IPA bytes.

Validation and limits
---------------------
Host checks present in this branch:

  sh xbmc/platform/darwin/ios/tests/run-host-tests.sh
  python3 tools/depends/target/ffmpeg/tests/check-linear-neon.py <FFmpeg source>

In the reconstructed InputStream Adaptive checkout:

  bash tools/tests/test_apple_aes.sh <patched Bento4 source> <test output>
  SANITIZE=1 bash tools/tests/test_apple_aes.sh <patched Bento4 source> <asan output>

These checks passed during development: native video buffer/metadata handling,
tone mapping, format reuse, interruption policy, subtitle composition, FFmpeg
scalar/NEON comparisons and NIST/differential AES cases. The AES suite compares
5,280 cases and 72,076,256 bytes against the original implementation. The archive
helper also reconstructs and verifies the exact add-on source tree.

On-device checks covered fold/open/rotate touch operation, player controls, PiP,
HDR on/off, hardware H.264/HEVC and encrypted MPD playback. Profiling confirmed
Apple corecrypto's ARM AES instructions were used. The final observed Kodi CPU
mean was about 9.7% of one core for the tested 1080p50 MPD, versus about 11.1%
in the preceding measurement. These were sequential samples, not a controlled
battery or watt measurement; shared media-service CPU did not decrease in that
comparison. The Apple TV sample used different content and is not an equivalent
energy baseline. No general battery-life claim follows from these numbers.

OpenGL still draws Kodi's UI; this branch is not a Metal port. Unsupported
hardware codecs and known interlaced input retain fallback paths. PiP without
subtitles uses the original decoded buffers; visible PiP subtitles use bounded
CPU YUV scaling/blending (up to 960x540) because background GPU work is restricted.
Native video is not included in Kodi's internal GL capture. Dolby Vision dynamic
metadata/enhancement layers are not guaranteed by HEVC decoding or HDR10 output.
UIKit system chrome may orient independently of the landscape Kodi canvas.
