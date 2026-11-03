import AppKit

enum Branding {
    static let appName = "CAM"
    static let fullName = "Codex Account Manager"
    static let appIcon: NSImage? = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    static let editIcon = templateImage("Edit")
    static let switchAccountIcon = templateImage("SwitchAccount")

    private static func templateImage(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }

    static func menuBarImage() -> NSImage {
        if let image = appIcon?.copy() as? NSImage {
            image.size = NSSize(width: 20, height: 20)
            image.isTemplate = false
            image.accessibilityDescription = appName
            return image
        }
        return NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: appName)
            ?? NSImage(size: NSSize(width: 20, height: 20))
    }
}
