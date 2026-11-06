# Cinema transport stream remuxer

KinoCinemaRemux copies the video and audio tracks from local MPEG transport streams into an MP4 container. It does not re-encode the streams. KinoPub loads it as a separate dynamic framework on visionOS.

The framework contains FFmpeg 8.0.1 and the C wrapper in this directory. Both use the GNU Lesser General Public License version 2.1 or later. The build does not enable GPL or nonfree components. See the included license.

Use Xcode with the visionOS SDK. Run `scripts/build-vision-cinema-remux.sh` from the repository root to download the exact source archive, check its checksum, and build both framework slices. To use a modified framework, replace the XCFramework, rebuild KinoPub, and sign the app for your device.

[FFmpeg 8.0.1 source archive](https://ffmpeg.org/releases/ffmpeg-8.0.1.tar.xz) · [FFmpeg license terms](https://ffmpeg.org/legal.html)
