<p align="center"><img src="docs/icon.png" width="128" alt="iPad Live icon"></p>

# iPad Live

Show your iPad's screen on your Mac, live and lag-free, so you can share it in Zoom, Google Meet or FaceTime.

Plug your iPad into your Mac with a cable and open **iPad Live**. A clean window on your Mac then shows exactly what's on your iPad: your drawing in Concepts, your notes, any app. In your meeting, share that window (or your whole Mac screen) instead of sharing the iPad directly.

## Why this is smoother than sharing your iPad in Zoom

When you share an iPad in Zoom, the iPad has to compress its screen and send it over Wi-Fi (AirPlay) or through the Zoom iPad app. That adds delay and drops frames, which is why your strokes show up late and jumpy.

iPad Live uses the cable instead. It's the same path QuickTime Player uses to record an iPad's screen: full resolution and full frame rate, with almost no delay. The picture goes straight from the cable to your Mac's graphics card, with no copying or re-compressing in between. Your meeting app then shares a normal Mac window, which it handles well.

## Requirements

- A Mac with **macOS 14 Sonoma or later**
- A **USB cable** that carries data, from your iPad to your Mac (USB-C to USB-C for newer iPads)
- **Xcode Command Line Tools** to build the app (free, see below)

## Install

1. Install Apple's free developer tools, if you haven't already. Open Terminal and run:

   ```bash
   xcode-select --install
   ```

2. Download this project and build the app:

   ```bash
   git clone https://github.com/calebynhan/ipad-live.git
   ```

   ```bash
   cd ipad-live
   ```

   ```bash
   make install
   ```

   This builds **iPad Live** and puts it in your Applications folder. (`make run` builds it and opens it without installing.)

> **Prefer a ready-made download?** Every push builds the app on GitHub. Open the repo's **Actions** tab, click the latest **Build** run, and download **iPad-Live** at the bottom. The app isn't notarized by Apple, so the first time macOS will refuse to open it. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. Building it yourself avoids this.

## First run

1. Open **iPad Live**.
2. macOS asks for **Camera** access. Click **Allow**. macOS treats a plugged-in iPad's screen like a camera, which is why it asks. Your Mac's own camera is never turned on.
3. Plug in your iPad and unlock it. If the iPad asks **"Trust This Computer?"**, tap **Trust** and enter your passcode.
4. Your iPad's screen appears in the window within a second or two.

From then on, open the app and plug in the iPad. It connects on its own, and reconnects if you unplug and plug back in.

## Sharing in a meeting

Share the **iPad Live** window. It has no title bar or buttons (they only show when your pointer is over it), so people see just your iPad.

| App | How |
|---|---|
| **Zoom** | **Share Screen** → pick **iPad Live**. Tick **Optimize for video clip** at the bottom-left of the share picker so your drawing looks smooth to others. |
| **Google Meet** | **Share screen** → **Window** → **iPad Live** |
| **FaceTime** | **Share Screen** → **Window**, then click the iPad Live window |

You can also go full screen (double-click the picture) and share your whole screen.

**If the iPad looks smooth on your Mac but choppy to others:** that's the meeting app squeezing its screen share to save bandwidth, and iPad Live can't change that. In Zoom, **Optimize for video clip** makes the biggest difference. You can also raise the limit in Zoom **Settings → Share Screen → Advanced → Limit your screen share to … frames per second**.

## Tips for presenting

- **Keep the iPad awake:** on the iPad, **Settings → Display & Brightness → Auto-Lock → Never**.
- **Hide notifications:** turn on **Do Not Disturb** on the iPad.
- **Hide the iPad's clock and battery:** **View → Hide iPad Status Bar** (⌘B).
- **Keep the window above other apps:** **View → Float on Top** (⌥⌘T).
- **Rotate freely:** turn the iPad and the window reshapes itself to match.

## Controls

| | |
|---|---|
| Move the window | Drag anywhere on the picture |
| Full screen | Double-click the picture, or ⌃⌘F |
| Fit window to the iPad's shape | ⌘0 |
| Hide iPad status bar | ⌘B |
| Float on top | ⌥⌘T |
| Reconnect | ⌘R |
| Pick an iPad (if several are plugged in) | **Device** menu |
| Hear the iPad's sound on the Mac | **Device → Play iPad Sound on This Mac** |
| Background colour around the picture | **View → Background** |

iPad Live only *shows* your iPad. You keep drawing and tapping on the iPad itself.

## Troubleshooting

**The window says "Connect Your iPad" but it's plugged in**
- Unlock the iPad, and tap **Trust** if it asks.
- Try another cable. Some cables only charge and don't carry data. If Finder doesn't show your iPad in its sidebar, the cable or port is the problem.
- Unplug and plug back in, or press ⌘R.

**The picture is black**
- Unlock the iPad. The picture pauses while it's locked or asleep.

**"Camera Access Is Off"**
- Click **Open Privacy Settings** and turn on **iPad Live** under **Camera**. If macOS asks to quit and reopen the app, do it.
- After you rebuild the app, macOS may ask for permission again. That's normal for apps you build yourself.

**My iPad went quiet while connected**
- While it's connected, the iPad may send its sound to the Mac. Turn on **Device → Play iPad Sound on This Mac** to hear it. macOS asks for Microphone permission, because it treats the iPad's sound like a microphone. Your Mac's own microphone is never used.

## Wireless?

iPad Live uses a cable on purpose, because that's what makes it lag-free. If you can live with some delay, macOS has wireless mirroring built in: on the iPad, open **Control Center → Screen Mirroring** and choose your Mac. Expect a fraction of a second of lag and the occasional stutter on busy Wi-Fi.

## How it works (for the curious)

- `ScreenCaptureDevices.swift` turns on CoreMediaIO's `kCMIOHardwarePropertyAllowScreenCaptureDevices`. Every app has this off by default. Once it's on, connected iPads and iPhones appear to AVFoundation as external "muxed" (video + audio) capture devices.
- `MirrorSession.swift` watches for those devices, opens the iPad in an `AVCaptureSession` on a background queue, and handles unplugging, errors and rotation.
- `MirrorView.swift` draws the session with `AVCaptureVideoPreviewLayer`. Frames go to the window server on the GPU without being copied or re-encoded, which is the lowest-latency way to show a capture device on macOS. A clipping layer trims the status bar.
- `MirrorWindowController.swift` is the chrome-free window: it reshapes on rotation, hides its buttons when the pointer leaves, and hides the pointer when it rests over the picture.
- `Sources/iPadLiveCore` holds the layout math, with unit tests (`make test`, needs full Xcode).

## Project layout

```
Package.swift                 Swift package (no Xcode project needed)
Sources/iPadLive/             The Mac app
Sources/iPadLiveCore/         Layout math (unit tested)
Tests/iPadLiveCoreTests/      Tests for the layout math
Resources/Info.plist          App info and permission messages
Resources/AppIcon.icns        App icon
scripts/build-app.sh          Builds and signs build/iPad Live.app
Makefile                      make app | run | install | test | clean
```
