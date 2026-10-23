# ios-remote-screen

Use an iPhone that is plugged into a Mac from anywhere, in a browser. You see the screen live and control it with touch, swipes, typing and the Home, App Switcher and Spotlight buttons. It works like [scrcpy](https://github.com/Genymobile/scrcpy) for Android or Apple's iPhone Mirroring, but:

- the phone can be plugged into a **remote** Mac (a device lab, a CI box, the Mac under your desk);
- it needs **no Apple Account pairing and no app on the phone**;
- the server listens on **127.0.0.1 only**, so you reach it through an SSH port forward, and an access token protects it.

```
browser ── ssh -L ──▶ server Mac 127.0.0.1:8765 ──▶ ios-remote-screen ──USB──▶ iPhone
                                                     ├─ video: CoreMediaIO screen capture (QuickTime's path)
                                                     └─ input: Xcode CoreDevice HID services (touch, buttons, keys)
```

> **Unofficial.** This project is not affiliated with Apple. For input it calls private Apple frameworks that ship with Xcode, through interfaces reconstructed from their exported symbols (see [How it works](#how-it-works)). Those APIs can change with any Xcode release. Use it only with devices you own or are authorized to use.

## Requirements

**Server (the Mac with the iPhone attached)**

- macOS 14 or later with **Xcode 27 or later** installed. The touch, button and keyboard services come from Xcode 27's Developer Disk Image.
- The iPhone is connected by USB, trusted, and has **Developer Mode** on (Settings → Privacy & Security → Developer Mode).
- For full-rate video, give **Camera** permission to the process running `ios-remote-screen`. Without it (for example, when the server is started over SSH), video falls back to Apple's `devicectl` screenshots at about 1 fps. Input still works.

**Client (your laptop):** an SSH client and a browser.

## Build (on the server)

```sh
git clone https://github.com/agrim0312/ios-remote-screen.git
cd ios-remote-screen
swift build -c release
.build/release/ios-remote-screen --list-devices      # shows attached iPhones
```

## Use

1. **On the server**, start the relay:

   ```sh
   .build/release/ios-remote-screen --device "<name or UDID>" --allow-shutdown --exit-with-stdin
   ```

   It prints a URL with a random access token, such as `http://127.0.0.1:8765/?token=…`.

   You can also start it from your laptop over SSH. Then the relay lives exactly as long as that SSH session:

   ```sh
   ssh user@server 'cd ios-remote-screen && .build/release/ios-remote-screen --device "<UDID>" --allow-shutdown --exit-with-stdin'
   ```

2. **On your laptop**, forward the port and open the printed URL:

   ```sh
   ssh -N -L 8765:127.0.0.1:8765 user@server
   open "http://127.0.0.1:8765/?token=<token>"
   ```

3. **In the viewer:**

   | Action | Result |
   |---|---|
   | Drag on the screen | Live finger |
   | Scroll wheel / trackpad | Swipe |
   | Click the screen, then type | Typing (US keyboard layout) |
   | Home / App Switcher / Spotlight buttons | Same as on the phone |
   | **Stop session** | Exits the relay on the server, which also ends the SSH session started in step 1 |

   With `--exit-with-stdin`, losing the SSH connection or pressing Ctrl-C also stops the relay, so no process is left running on the server. Run that `ssh` command in the foreground of a terminal. Started with `ssh -n`, or in the background with stdin closed, the relay sees stdin close at once and exits.

### Options

| Flag | Default | Meaning |
|---|---|---|
| `--device D` | the only attached iPhone | Device name, UDID or CoreDevice identifier |
| `--port N` | 8765 | Loopback port |
| `--token T` / `--no-token` | random | Access token for the page and the WebSocket |
| `--video auto\|usb\|screenshot` | auto | `usb` uses CoreMediaIO (needs Camera permission). `screenshot` uses `devicectl` at about 1 fps. `auto` picks `usb` when permission is granted. |
| `--display D` | auto | Screenshot video on multi-display devices (foldables like iPhone Duo): a display unique ID or number. `auto` follows the active display. Touches go to that display and are rotated to match. You can also switch displays mid-session from the viewer's **display menu**, which appears when the device has more than one screen. |
| `--fps N`, `--quality Q`, `--max-width W` | 30, 0.6, native | Stream size and rate |
| `--view-only` | off | Ignore all input |
| `--allow-shutdown` | off | Show the **Stop session** button |
| `--exit-with-stdin` | off | Exit when stdin closes, for example when the SSH session ends |
| `--list-devices` | | Print attached iPhones as JSON |
| `--source mirroring` | | Drive the macOS **iPhone Mirroring** window instead (needs the same Apple Account on the Mac and the phone, plus Screen Recording and Accessibility permissions) |

Endpoints: `/` viewer, `/ws` stream and control, `/status` JSON, `/snapshot.jpg` latest frame, `/healthz`. Every endpoint except `/healthz` requires `?token=`.

## How it works

The design came from reverse engineering Apple's tooling with [REA](https://github.com/morluto/rea), using Hopper and static inspection only.

| Finding | Use in this tool |
|---|---|
| Xcode 27's iOS Developer Disk Image ships `dtuhidd`. It serves `com.apple.coredevice.hid.indigo` (digitizer, button, scroll) and `…hid.universalhid` (keyboard). It also ships `dtremotedisplayd`, a live screen stream. | Input needs no app on the phone. |
| `CoreDevice.framework` exposes these as capabilities: `RemoteDevice.getImplementation(for: .hid.digitizer / .hid.button)`, then `HIDDigitizer.send(pointOne:pointTwo:eventType:edge:target:)` and `HIDButton.sendCustomButton(usagePage:usageCode:state:)`. | `Interfaces/` has hand-written Swift module interfaces for exactly these symbols. Points are normalized 0–1. Home is HID consumer page 0x0C, usage 0x40. Keys are on HID page 0x07. |
| Capabilities are only offered while the CoreDevice tunnel is up. | The relay holds a usage assertion (`acquireDeviceUsageAssertion`, requiring DDI services). |
| `avconferenced` refuses the CoreDevice screen stream to non-Apple clients. | Video uses the public CoreMediaIO screen-capture device instead. It does not try to get around that check. |
| Some UniversalHID value types are fixed-layout. Runtime value-witness sizes confirmed this. | They are declared `@frozen` in `Interfaces/UniversalHID…`. |

The `mirroring` source is based on a REA analysis of `iPhone Mirroring.app`:

- Every input event in `CaptureViewController` is turned into UniversalHID reports, so synthesized Mac events are enough to control it.
- The app tells the phone when its window is being captured, but the session continues.

If an Xcode update breaks the private interfaces, regenerate the symbol lists from the new frameworks (for example with `rea inspect-macho`) and update `Interfaces/`.

## Limitations

- These are private APIs, and Xcode updates can break them.
- Only one finger. Rotation is handled for screenshot video (tested on iPhone Duo's inner display in landscape); USB-capture video assumes portrait.
- Typing covers US-layout ASCII. Other characters are skipped.
- Phones show the clean 9:41 status bar while they are being captured.
- The screenshot fallback runs at about 1 fps.

## Development

```sh
swift build && swift test
```

## License

MIT. See [LICENSE](LICENSE).
