# Android multitasking and device compatibility

## Compatibility contract

NETWORK is an Android APK. The current release workflow configures Android minSdk 26 (Android 8.0), so this build targets Android phones running Android 8.0 or newer. It is not an iOS application.

The app must not assume Samsung One UI, a specific launcher, a vendor floating-window feature, a fixed screen size, or a particular CPU ABI. Runtime capabilities are detected on the device and optional features degrade gracefully.

## Window strategy

1. NETWORK's own assistant bubble remains an application overlay and requires the Android overlay permission.
2. NETWORK activities declare `resizeableActivity=true` so the NETWORK UI can participate in Android multi-window.
3. The agent exposes `phone_window_capabilities` to inspect Android API level, freeform feature availability, low-RAM status, and overlay permission.
4. `phone_open_app_window` requests Android adjacent/split-screen launching using public Intent flags on Android 7.0+.
5. If the device, OEM firmware, or target app does not support multi-window/freeform, Android may ignore the request. NETWORK must report the fallback and open the app normally instead of claiming a floating app window was created.

A third-party APK cannot force arbitrary installed apps into freeform windows on every Android phone using public APIs. Freeform is an OEM/device capability; split-screen behavior is controlled by Android and the target app's resizability. Do not use hidden APIs or root-only window-manager commands as a compatibility requirement.

## Isolated background-window control

- `phone_window_list` enumerates application windows exposed by `AccessibilityService.getWindows()`, including package, window ID, focus state, and screen bounds.
- `phone_window_read`, `phone_window_tap_text`, `phone_window_type_text`, and `phone_window_scroll` target a specific package and, when supplied, a specific window ID. This supports multiple instances of the same package when Android exposes them separately.
- These operations use `AccessibilityNodeInfo` actions on the selected window. They must never fall back to `dispatchGesture`, coordinate taps, global swipes, or global keyboard input. If the target window does not expose an actionable node, return a failure rather than interacting with the user's foreground screen.
- Opening an app in freeform is a request, not a guarantee. NETWORK verifies the actual window list before claiming an independent window exists. A device may allow only split-screen, may not support freeform, or may reject resizing for a particular app.
- The number of simultaneously open windows is determined by Android, the OEM, available memory, and the target apps; NETWORK must not invent an unlimited device capability.

## Parallel execution

- Independent read-only tool batches may execute concurrently, with a maximum of eight workers per batch.
- Mutating operations within one app/window remain ordered. Separate app windows can be inspected and addressed by their own window IDs; do not use global touch/keyboard gestures for background-window work.
- Background network, repository, and diagnostic work can overlap when the tools are independent.
- Background-window commands use per-window accessibility node actions. Apps that require a physical gesture, a focused IME, secure surfaces, or custom canvas interaction may not be controllable without foreground interaction.

## Device validation matrix

Validate on emulators and physical devices across:
- Android 8, 10, 12, 13, 14, 15, and 16 where available;
- low-RAM and standard devices;
- overlay permission granted and denied;
- accessibility enabled and disabled;
- OEMs with split-screen/freeform and OEMs without freeform;
- target apps that allow and disallow resizing.

Required checks: normal app launch, assistant overlay lifecycle, capability detection, freeform/adjacent-window request, full-screen fallback, per-window read/click/set-text/scroll, repeated instances selected by window ID, and verification that background-window commands do not dispatch global gestures or steal foreground interaction.
