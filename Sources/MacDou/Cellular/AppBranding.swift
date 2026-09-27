import AppKit
import Combine

/// Full-color application branding is separate from the live signal glyph.
@MainActor
enum AppBranding {
    static func icon(in bundle: Bundle = .main) -> NSImage? {
        guard let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let url = bundle.url(forResource: name, withExtension: (name as NSString).pathExtension.isEmpty ? "icns" : nil) else { return nil }
        return NSImage(contentsOf: url)
    }

    static func imageView(image: NSImage? = nil) -> NSImageView {
        let view = NSImageView()
        view.image = image ?? icon()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.identifier = NSUserInterfaceItemIdentifier("application-brand-icon")
        // The adjacent application name supplies the accessible label.
        view.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 40),
            view.heightAnchor.constraint(equalToConstant: 40)
        ])
        return view
    }
}
