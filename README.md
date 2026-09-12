VirtualCamera tweak. Replaces the camera's image/video output with an arbitrary image or video file. Tested on iOS 15 - 17

## Usage

After installation, open the **VCam** app from the Home Screen. Use **Chọn ảnh** or **Chọn video**, then enable the VCam switch. The app copies the selected media, updates the tweak preferences, and reloads the replacement automatically.

The floating control also has image, video, and live-link actions. Disabling VCam hides both the floating button and its panel. Live image URLs are polled once per second; HLS, MP4, MJPEG, and RTSP video URLs are decoded by FFmpeg into a low-latency 15 FPS camera path at 480px, tuned for iPhone 7/A10. Limited-range video is expanded correctly when zscale is unavailable, and HDR tone-mapping automatically falls back to this compatible decoder.

## Build on Windows

This repository includes a GitHub Actions workflow because Theos requires a Linux or macOS build environment.

1. Push the repository to GitHub.
2. Open the repository's **Actions** tab and run **Build tweak** (or push a commit).
3. Open the completed workflow run and download the `vcam-rootful-rootless-roothide-debs` artifact. It contains three files:
   - `iphoneos-arm` for rootful jailbreaks
   - `iphoneos-arm64` for standard rootless jailbreaks
   - `iphoneos-arm64e` for RootHide jailbreaks
4. Install the matching file with Sileo/Zebra, or with `dpkg -i` over SSH. The workflow also publishes all three packages to the Sileo source:

   https://vinhnv2507.github.io/vcamios

   Add that URL in Sileo (Sources -> Edit -> +), then pull down on the source list to refresh. Package name: vcam.

VCam requires a jailbroken device with tweak injection (Substrate/ElleKit). It cannot replace the camera on a stock, non-jailbroken iPhone.

This works by hooking into `mediaserverd`, which is responsible for, among other things, connecting to the camera hardware and forwarding image data to interested clients (such as user-installed apps). VCam works in apps even if they don't have tweak injection

This is POC stage. The filepath to the "replacement media" is hardcoded in `image_utils.m`. Memory leaks kill `mediaserverd` every 30s

**image file** 
---
<img src=".imgs/image.png"  width="50%">

**video file**
---
<img src=".imgs/video.gif" width="50%">
