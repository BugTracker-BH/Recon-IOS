# UniCam — camera-frame injector (authorized liveness testing)

For the **Unico IDTech HackerOne** liveness bug-bounty, on **in-scope test apps**,
on a device **you own**. Replaces the live camera feed with frames decoded from a
spoof video so you can test the Presentation-Attack / Data-Flow matrices.

## Pieces
- `recon.js` — Frida script: maps the SDK's capture pipeline + backend upload.
  Run this FIRST to confirm the SDK uses `AVCaptureVideoDataOutput` (what the
  tweak hooks) and to grab the app bundle id + submission URL.
- `tweak/` — the injector dylib (rootless ElleKit) + `.deb` packaging.

## Step 1 — recon
```bash
# custom port helps vs frida detection:
frida-server -l 0.0.0.0:47000   # on device
frida -H <device-ip>:47000 -f <bundle.id> -l recon.js --no-pause
```
Note from the output:
- the **app bundle id**  -> put it in `UniCam.plist` (replace the placeholder)
- the `<-- injection point` delegate class (confirms the tweak will catch frames)
- the `[net]` submission URL (server-side decision endpoint)

## Step 2 — set the injection filter
Edit `tweak/layout/.../UniCam.plist`, replace `REPLACE.WITH.UNICO.APP.BUNDLEID`
with the real bundle id from recon. (Narrow targeting avoids injecting globally.)

## Step 3 — build + install
```bash
cd tweak
make clean
make package SYSROOT=$HOME/theos/sdks/iPhoneOS16.5.sdk
# -> build/com.local.unicam_1.0.0_iphoneos-arm64.deb  (install on device)
```
Put your spoof clip at `/var/mobile/Documents/vcam.mp4`, install the .deb,
respring, launch the app, run a liveness capture.

## Honest caveats (read these)
- **Jailbreak/Frida detection**: install Shadow (or similar) and hide the app
  first, or the SDK may refuse/auto-fail before injection matters.
- **Pixel format**: the tweak re-renders via CIContext to match the original
  buffer's format. If recon shows the SDK requests an unusual format, we tune
  `MakeMatchingBuffer`.
- **If the SDK uses `AVCapturePhotoOutput` or a custom pipeline** (recon will
  show this), this video-data-output hook won't catch it and we add a second
  hook for that path.
- **Server-side decision**: a positive result must come back from the backend
  (`live:true`). This tool produces a well-formed injected stream; whether it
  passes is exactly what you're testing/reporting.
