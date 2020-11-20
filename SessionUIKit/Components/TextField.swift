import UIKit

public final class TextField : UITextField {
    private let usesDefaultHeight: Bool
    private let height: CGFloat
    private let horizontalInset: CGFloat
    private let verticalInset: CGFloat

    public init(placeholder: String, usesDefaultHeight: Bool = true, customHeight: CGFloat? = nil, customHorizontalInset: CGFloat? = nil, customVerticalInset: CGFloat? = nil) {
        self.usesDefaultHeight = usesDefaultHeight
        self.height = customHeight ?? Values.textFieldHeight
        self.horizontalInset = customHorizontalInset ?? (isIPhone5OrSmaller ? Values.mediumSpacing : Values.largeSpacing)
        self.verticalInset = customVerticalInset ?? (isIPhone5OrSmaller ? Values.smallSpacing : Values.largeSpacing)
        super.init(frame: CGRect.zero)
        self.placeholder = placeholder
        setUpStyle()
    }
    
    public override init(frame: CGRect) {
        preconditionFailure("Use init(placeholder:) instead.")
    }
    
    public required init?(coder: NSCoder) {
        preconditionFailure("Use init(placeholder:) instead.")
    }
    
    private func setUpStyle() {
        textColor = Colors.text
        font = .systemFont(ofSize: Values.smallFontSize)
        let placeholder = NSMutableAttributedString(string: self.placeholder!)
        let placeholderColor = Colors.text.withAlphaComponent(Values.unimportantElementOpacity)
        placeholder.addAttribute(.foregroundColor, value: placeholderColor, range: NSRange(location: 0, length: placeholder.length))
        attributedPlaceholder = placeholder
        tintColor = Colors.accent
        keyboardAppearance = isLightMode ? .light : .dark
        if usesDefaultHeight {
            set(.height, to: height)
        }
        layer.borderColor = isLightMode ? Colors.text.cgColor : Colors.border.withAlphaComponent(Values.textFieldBorderOpacity).cgColor
        layer.borderWidth = Values.borderThickness
        layer.cornerRadius = Values.textFieldCornerRadius
    }
    
    public override func textRect(forBounds bounds: CGRect) -> CGRect {
        if usesDefaultHeight {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        } else {
            return bounds.insetBy(dx: Values.mediumSpacing, dy: Values.smallSpacing)
        }
    }
    
    public override func editingRect(forBounds bounds: CGRect) -> CGRect {
        if usesDefaultHeight {
            return bounds.insetBy(dx: horizontalInset, dy: verticalInset)
        } else {
            return bounds.insetBy(dx: Values.mediumSpacing, dy: Values.smallSpacing)
        }
    }
}
