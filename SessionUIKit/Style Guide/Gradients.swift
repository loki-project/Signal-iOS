import UIKit

@objc(LKGradient)
public final class Gradient : NSObject {
    public let start: UIColor
    public let end: UIColor

    private override init() { preconditionFailure("Use init(start:end:) instead.") }

    @objc public init(start: UIColor, end: UIColor) {
        self.start = start
        self.end = end
        super.init()
    }
}

@objc public extension UIView {

    @objc func setGradient(_ gradient: Gradient) {
        let layer = CAGradientLayer()
        layer.frame = UIScreen.main.bounds
        layer.colors = [ gradient.start.cgColor, gradient.end.cgColor ]
        if let existingSublayer = self.layer.sublayers?[0], existingSublayer is CAGradientLayer {
            self.layer.replaceSublayer(existingSublayer, with: layer)
        } else {
            self.layer.insertSublayer(layer, at: 0)
        }
    }
}

@objc(LKGradients)
final public class Gradients : NSObject {

    @objc public static var defaultLokiBackground: Gradient {
        switch AppModeManager.shared.currentAppMode {
        case .light: return Gradient(start: UIColor(hex: 0xFCFCFC), end: UIColor(hex: 0xFFFFFF))
        case .dark: return Gradient(start: UIColor(hex: 0x171717), end: UIColor(hex: 0x121212))
        }
    }

    @objc public static var homeVCFade: Gradient {
        switch AppModeManager.shared.currentAppMode {
        case .light: return Gradient(start: UIColor(hex: 0xFFFFFF).withAlphaComponent(0), end: UIColor(hex: 0xFFFFFF))
        case .dark: return Gradient(start: UIColor(hex: 0x000000).withAlphaComponent(0), end: UIColor(hex: 0x000000))
        }
    }
}
