# KinoPub for Apple Vision Pro

## Install the preview

The IPA needs a signature and a provisioning profile for your Vision Pro. You can also build the app from source with Xcode.

## Build from source

Use Xcode 27 with the visionOS SDK installed.

1. Open `KinoPubAppleClient.xcodeproj`.
2. Select the `KinoPubAppleClient` scheme.
3. Select your Apple Vision Pro as the run destination.
4. Select your development team in Signing & Capabilities.
5. Set a bundle identifier that your provisioning profile permits.
6. Click Run to build and install the app.

## Open a video in full screen

Start a movie or episode. Select **Open in Full Screen** above the video. Use the system playback controls to return to the window.

## Select video quality

Open the native **Quality** menu in the playback window or use the **Quality** tab in the system player. The panel shows the resolution in use. For 3D streams, selecting a resolution switches to that version of the video. **Auto** lets the player adapt to the connection.

## Watch a 3D movie in an Apple Environment

1. Play a title from the 3D section.
2. Select **Apple Cinema** in the playback controls.
3. Select **Prepare Movie**. Keep KinoPub open during the download and conversion. Preparation can take several minutes and needs free storage.
4. Select **Open in Apple Player**.
5. Open the system playback controls.
6. Select **Watch in Apple Environment**.

The prepared movie has a native stereo video track and uses the playback language settings from Profile. Use Apple’s timeline to seek. If KinoPub cannot find a requested audio track or full subtitle track, it reports the missing track. The app removes the temporary copy when you leave the movie.

## Adjust the 3D eye alignment

Open **3D Format** during packed 3D playback. Use the vertical and horizontal sliders or the arrow buttons to adjust the right eye relative to the left. KinoPub saves the adjustment for that title and format. Set it before you prepare the movie for Apple Cinema. Select **Reset Alignment** to restore automatic vertical alignment and center the horizontal adjustment.

## Set the playback languages

Open **Profile**, then **Playback Languages**. Select **System Default**, **Original Audio + English Subtitles**, or **Custom**. In Custom, select the audio and subtitle languages separately. Select **Off** to turn subtitles off.

## Watch movies and episodes in Multiview

1. Open **Profile**.
2. Turn on **Multiview for Movies and Series**.
3. Open a 2D movie or an episode.
4. Select **Add to Multiview**. On an episode card, use its context menu.
5. Add at least one more video.
6. Open **Multiview** from the library controls.
7. Select **Start Multiview**.

Multiview supports up to five videos. Search for another title from the system content selector to add it during playback. For series, this opens the next episode from Continue Watching or the first available episode. Use **Listen** to choose which video plays audio.

The [Cinema remux framework](Vendor/KinoCinemaRemux/README.md) includes its license and build instructions.
