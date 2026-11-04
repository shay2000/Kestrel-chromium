import Foundation

enum BrowserPageGeometry {
    /// Crop chrome from the physical top of a native view, including flipped
    /// views. Snapshots and cursor coordinates must remain page-only.
    static func contentRect(in bounds: CGRect, headerHeight: CGFloat, isFlipped: Bool) -> CGRect {
        let header = min(max(0, headerHeight), bounds.height)
        return CGRect(x: bounds.minX, y: bounds.minY + (isFlipped ? header : 0),
                      width: bounds.width, height: bounds.height - header)
    }
    /// Cover the complete host region at backing-pixel boundaries. Rounding
    /// inward can expose a hairline between the toolbar and the native page.
    static func coveringFrame(_ frame: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(1, scale)
        let left = (frame.minX * scale).rounded(.down) / scale
        let bottom = (frame.minY * scale).rounded(.down) / scale
        let right = (frame.maxX * scale).rounded(.up) / scale
        let top = (frame.maxY * scale).rounded(.up) / scale
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }
}
