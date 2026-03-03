import Cocoa

enum DockPosition {
    case bottom
    case left
    case right
    case unknown
}

final class DockUtils {
    static let shared = DockUtils()

    private let dockDefaults: UserDefaults?

    private init() {
        dockDefaults = UserDefaults(suiteName: "com.apple.dock")
    }

    func isDockHidingEnabled() -> Bool {
        dockDefaults?.bool(forKey: "autohide") ?? false
    }

    func countIcons() -> (Int, Int) {
        let persistentAppsCount = dockDefaults?.array(forKey: "persistent-apps")?.count ?? 0
        let recentAppsCount = dockDefaults?.array(forKey: "recent-apps")?.count ?? 0
        return (persistentAppsCount + recentAppsCount, (persistentAppsCount > 0 && recentAppsCount > 0) ? 1 : 0)
    }

    func calculateDockWidth() -> CGFloat {
        let counts = countIcons()
        let iconCount = counts.0
        let numberOfDividers = counts.1
        let tile = tileSize()

        let baseWidth = tile * CGFloat(iconCount)
        let dividerWidth: CGFloat = 10.0
        let totalDividerWidth = CGFloat(numberOfDividers) * dividerWidth

        if isMagnificationEnabled(), let largeSize = dockDefaults?.object(forKey: "largesize") as? CGFloat {
            let extraWidth = (largeSize - tile) * CGFloat(iconCount) * 0.5
            return baseWidth + extraWidth + totalDividerWidth
        }

        return baseWidth + totalDividerWidth
    }

    private func tileSize() -> CGFloat {
        dockDefaults?.double(forKey: "tilesize") ?? 0
    }

    private func largeSize() -> CGFloat {
        dockDefaults?.double(forKey: "largesize") ?? 0
    }

    func isMagnificationEnabled() -> Bool {
        dockDefaults?.bool(forKey: "magnification") ?? false
    }

    func calculateDockHeight(_ forScreen: NSScreen?) -> CGFloat {
        if isDockHidingEnabled() {
            return abs(largeSize() - tileSize())
        }
        guard let screen = forScreen else { return 0.0 }
        switch getDockPosition(screen: screen) {
        case .right, .left:
            return abs(screen.frame.width - screen.visibleFrame.width)
        case .bottom:
            let size = screen.frame.height - screen.visibleFrame.height - getStatusBarHeight(screen: screen) - 1
            return size
        case .unknown:
            return 0.0
        }
    }

    func getStatusBarHeight(screen: NSScreen?) -> CGFloat {
        guard let screen else { return 0.0 }
        return screen.frame.height - screen.visibleFrame.height - (screen.visibleFrame.origin.y - screen.frame.origin.y) - 1
    }

    func getDockPosition(screen: NSScreen? = NSScreen.main) -> DockPosition {
        guard let screen else { return .unknown }
        if let orientation = dockDefaults?.string(forKey: "orientation")?.lowercased() {
            switch orientation {
            case "left":
                return .left
            case "bottom":
                return .bottom
            case "right":
                return .right
            default:
                return .unknown
            }
        }

        if screen.visibleFrame.origin.y == screen.frame.origin.y && !isDockHidingEnabled() {
            if screen.visibleFrame.origin.x == screen.frame.origin.x {
                return .right
            }
            return .left
        }
        return .bottom
    }
}
