
final class FakeChatView : UIView {
    private let spacing = Values.mediumSpacing
    
    var contentOffset: CGPoint {
        get { return scrollView.contentOffset }
        set { scrollView.contentOffset = newValue }
    }
    
    private lazy var chatBubbles = [
        getChatBubble(withText: NSLocalizedString("view_fake_chat_bubble_1", comment: ""), wasSentByCurrentUser: true),
        getChatBubble(withText: NSLocalizedString("view_fake_chat_bubble_2", comment: ""), wasSentByCurrentUser: false),
        getChatBubble(withText: NSLocalizedString("view_fake_chat_bubble_3", comment: ""), wasSentByCurrentUser: true),
        getChatBubble(withText: NSLocalizedString("view_fake_chat_bubble_4", comment: ""), wasSentByCurrentUser: false),
        getChatBubble(withText: NSLocalizedString("view_fake_chat_bubble_5", comment: ""), wasSentByCurrentUser: false)
    ]
    
    private lazy var scrollView: UIScrollView = {
        let result = UIScrollView()
        result.showsHorizontalScrollIndicator = false
        result.showsVerticalScrollIndicator = false
        return result
    }()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setUpViewHierarchy()
        animate()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViewHierarchy()
        animate()
    }
    
    private func setUpViewHierarchy() {
        let stackView = UIStackView(arrangedSubviews: chatBubbles)
        stackView.axis = .vertical
        stackView.spacing = spacing
        stackView.alignment = .fill
        stackView.set(.width, to: UIScreen.main.bounds.width)
        stackView.layoutMargins = UIEdgeInsets(top: 8, leading: Values.veryLargeSpacing, bottom: 8, trailing: Values.veryLargeSpacing)
        stackView.isLayoutMarginsRelativeArrangement = true
        scrollView.addSubview(stackView)
        stackView.pin(to: scrollView)
        addSubview(scrollView)
        scrollView.pin(to: self)
    }
    
    private func getChatBubble(withText text: String, wasSentByCurrentUser: Bool) -> UIView {
        let result = UIView()
        let bubbleView = UIView()
        bubbleView.set(.width, to: Values.fakeChatBubbleWidth)
        bubbleView.layer.cornerRadius = Values.fakeChatBubbleCornerRadius
        bubbleView.layer.shadowColor = UIColor.black.cgColor
        bubbleView.layer.shadowRadius = isLightMode ? 4 : 8
        bubbleView.layer.shadowOpacity = isLightMode ? 0.16 : 0.24
        bubbleView.layer.shadowOffset = CGSize.zero
        let backgroundColor = wasSentByCurrentUser ? Colors.fakeChatBubbleBackground : Colors.accent
        bubbleView.backgroundColor = backgroundColor
        let label = UILabel()
        let textColor = wasSentByCurrentUser ? Colors.text : Colors.fakeChatBubbleText
        label.textColor = textColor
        label.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.text = text
        bubbleView.addSubview(label)
        label.pin(to: bubbleView, withInset: 12)
        result.addSubview(bubbleView)
        bubbleView.pin(.top, to: .top, of: result)
        result.pin(.bottom, to: .bottom, of: bubbleView)
        if wasSentByCurrentUser {
            bubbleView.pin(.trailing, to: .trailing, of: result)
        } else {
            result.pin(.leading, to: .leading, of: bubbleView)
        }
        return result
    }
    
    private func animate() {
        let animationDuration = Values.fakeChatAnimationDuration
        let delayBetweenMessages = Values.fakeChatDelay
        chatBubbles.forEach { $0.alpha = 0 }
        Timer.scheduledTimer(withTimeInterval: Values.fakeChatStartDelay, repeats: false) { [weak self] _ in
            self?.showChatBubble(at: 0)
            Timer.scheduledTimer(withTimeInterval: 1.5 * delayBetweenMessages, repeats: false) { _ in
                self?.showChatBubble(at: 1)
                Timer.scheduledTimer(withTimeInterval: 1.5 * delayBetweenMessages, repeats: false) { _ in
                    self?.showChatBubble(at: 2)
                    UIView.animate(withDuration: animationDuration) {
                        guard let self = self else { return }
                        self.scrollView.contentOffset = CGPoint(x: 0, y: self.chatBubbles[0].height() + self.spacing)
                    }
                    Timer.scheduledTimer(withTimeInterval: 1.5 * delayBetweenMessages, repeats: false) { _ in
                        self?.showChatBubble(at: 3)
                        UIView.animate(withDuration: animationDuration) {
                            guard let self = self else { return }
                            self.scrollView.contentOffset = CGPoint(x: 0, y: self.chatBubbles[0].height() + self.spacing + self.chatBubbles[1].height() + self.spacing)
                        }
                        Timer.scheduledTimer(withTimeInterval: delayBetweenMessages, repeats: false) { _ in
                            self?.showChatBubble(at: 4)
                            UIView.animate(withDuration: animationDuration) {
                                guard let self = self else { return }
                                self.scrollView.contentOffset = CGPoint(x: 0, y: self.chatBubbles[0].height() + self.spacing + self.chatBubbles[1].height() + self.spacing + self.chatBubbles[2].height() + self.spacing)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func showChatBubble(at index: Int) {
        let chatBubble = chatBubbles[index]
        UIView.animate(withDuration: Values.fakeChatAnimationDuration) {
            chatBubble.alpha = 1
        }
        let scale = Values.fakeChatMessagePopAnimationStartScale
        chatBubble.transform = CGAffineTransform(scaleX: scale, y: scale)
        UIView.animate(withDuration: Values.fakeChatAnimationDuration, delay: 0, usingSpringWithDamping: 0.68, initialSpringVelocity: 4, options: .curveEaseInOut, animations: {
            chatBubble.transform = CGAffineTransform(scaleX: 1, y: 1)
        }, completion: nil)
    }
}
