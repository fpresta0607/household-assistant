// The screen a system sheet goes up over: what the active window shows on top. Some of
// Apple's sheets run outside the app and must be presented by UIKit itself.

import UIKit

extension UIApplication {
    var topmostViewController: UIViewController? {
        let scene = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }
}
