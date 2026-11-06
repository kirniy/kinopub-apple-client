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

## Select video quality

Open **Quality** in the playback window or in the system player’s information tabs. The panel lists the resolutions in the current stream and shows the resolution in use. Select **Auto** to let the player choose. A selection takes effect as the player loads more video.

For compatible video, select **Watch in Apple Environment** in the system player. For frame-packed 3D video, select **Full Screen** in KinoPub to open the large 3D window.
