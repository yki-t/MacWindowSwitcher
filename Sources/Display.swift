import AppKit

func displayUUID(_ display: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String?
}

func displayUUID(_ screen: NSScreen) -> String? {
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
    return displayUUID(CGDirectDisplayID(number.uint32Value))
}

func connectedScreen(uuid: String) -> NSScreen? {
    NSScreen.screens.first { screen in
        displayUUID(screen).map { $0.caseInsensitiveCompare(uuid) == .orderedSame } ?? false
    }
}
