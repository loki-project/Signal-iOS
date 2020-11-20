
@objc(LKAppearanceUtilities)
final class AppearanceUtilities : NSObject {

    @objc static func switchToSessionAppearance() {
        if #available(iOS 13, *) {
            UINavigationBar.appearance().barTintColor = Colors.navigationBarBackground
            UINavigationBar.appearance().isTranslucent = false
            UINavigationBar.appearance().tintColor = Colors.text
            UIToolbar.appearance().barTintColor = Colors.navigationBarBackground
            UIToolbar.appearance().isTranslucent = false
            UIToolbar.appearance().tintColor = Colors.text
            UISwitch.appearance().onTintColor = Colors.accent
            UINavigationBar.appearance().titleTextAttributes = [ NSAttributedString.Key.foregroundColor : Colors.text ]
        }
    }

    @objc static func switchToImagePickerAppearance() {
        if #available(iOS 13, *) {
            UINavigationBar.appearance().barTintColor = .white
            UINavigationBar.appearance().isTranslucent = false
            UINavigationBar.appearance().tintColor = .black
            UINavigationBar.appearance().titleTextAttributes = [ NSAttributedString.Key.foregroundColor : UIColor.black ]
        }
    }
}
