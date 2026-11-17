# window-switcher

Replaces the macOS Cmd+Tab app switcher with a window switcher.
Lists the windows on the visible Desktops (minimized windows and windows of hidden apps included) in most-recently-used order, with thumbnails.

## Requirements

- macOS 14 or later
- Xcode command line tools (Swift toolchain)

## Install

1. Create a self-signed code signing certificate named `window-switcher`. An ad hoc signature changes with each build, and macOS then asks for the permissions again.
   - Keychain Access > Certificate Assistant > Create a Certificate
   - Name: `window-switcher`
   - Identity Type: `Self Signed Root`
   - Certificate Type: `Code Signing`
2. Run `make install`. It builds and signs the app, copies it to `~/Applications/WindowSwitcher.app`, and starts it.
3. Allow the app in System Settings > Privacy & Security > Accessibility. The app starts to work after that.
4. Allow the app in System Settings > Privacy & Security > Screen & System Audio Recording, then run `make install` again. Thumbnails need a restart of the app. Without this permission, the app shows app icons in place of thumbnails.
5. Optional: select `Settings...` in the menu bar menu and turn on `Launch at Login`.

## Keys

| Key | Action |
|---|---|
| Cmd+Tab | Open the panel and select the previous window. With the panel open, move to the next window. |
| Cmd+Shift+Tab | Open the panel and select the last window. With the panel open, move to the previous window. |
| Left / Right arrow (panel open) | Move to the previous / next window. |
| Release Cmd | Switch to the selected window. |
| Esc | Close the panel without a switch. |
| Click on a tile | Switch to that window. |
| Option+H / Option+L | Move to the Space on the left / right. |
| Shift+Option+H / Shift+Option+L | Move the focused window to the Space on the left / right. |

The Option keys are off by default. Turn them on in `Settings...`.
Option+H / L use the physical H and L key positions of the ANSI layout (key codes 4 and 37).
They need the Mission Control shortcuts (Ctrl+Left / Right arrow) on in System Settings > Keyboard > Keyboard Shortcuts > Mission Control.

## Limitations

- It uses private APIs (`CGSSetSymbolicHotKeyEnabled`, `_AXUIElementGetWindow`, `CGSMainConnectionID`, `CGSGetActiveSpace`, `CGSCopyManagedDisplaySpaces`). A macOS update can stop it.
- It cannot be sandboxed and cannot be distributed through the Mac App Store.
- While Secure Input is on (for example, a password field has the focus), Cmd+Tab does nothing.
- Windows on other Desktops are not listed.
- Shift+Option+H / L cannot move a full screen window, and does nothing when the next Space is a full screen app. It can fail for an app that draws its own title bar.

## Recovery

The app disables the native Cmd+Tab while it runs and enables it again at `Quit`.
If the app stops abnormally, the native Cmd+Tab can stay disabled. Start the app again and select `Quit`.
This works only while the app has the Accessibility permission. If the permission was removed, allow it again first.

## License

MIT. See `LICENSE`.
