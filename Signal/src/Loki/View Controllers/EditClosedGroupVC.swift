
@objc(LKEditClosedGroupVC)
final class EditClosedGroupVC : BaseVC, UITableViewDataSource, UITableViewDelegate {
    private let thread: TSGroupThread
    private var name = ""
    private var members: [String] = [] { didSet { tableView.reloadData() } }
    private var isEditingGroupName = false { didSet { handleIsEditingGroupNameChanged() } }

    // MARK: Components
    private lazy var groupNameLabel: UILabel = {
        let result = UILabel()
        result.textColor = Colors.text
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.lineBreakMode = .byTruncatingTail
        result.textAlignment = .center
        return result
    }()

    private lazy var groupNameTextField: TextField = {
        let result = TextField(placeholder: "Enter a group name", usesDefaultHeight: false)
        result.textAlignment = .center
        return result
    }()

    private lazy var addMembersButton: Button = {
        let result = Button(style: .prominentOutline, size: .large)
        result.setTitle("Add Members", for: UIControl.State.normal)
        result.addTarget(self, action: #selector(addMembers), for: UIControl.Event.touchUpInside)
        result.contentEdgeInsets = UIEdgeInsets(top: 0, leading: Values.mediumSpacing, bottom: 0, trailing: Values.mediumSpacing)
        return result
    }()

    @objc private lazy var tableView: UITableView = {
        let result = UITableView()
        result.dataSource = self
        result.delegate = self
        result.register(UserCell.self, forCellReuseIdentifier: "UserCell")
        result.separatorStyle = .none
        result.backgroundColor = .clear
        result.isScrollEnabled = false
        return result
    }()

    // MARK: Lifecycle
    @objc(initWithThreadID:)
    init(with threadID: String) {
        var thread: TSGroupThread!
        Storage.read { transaction in
            thread = TSGroupThread.fetch(uniqueId: threadID, transaction: transaction)!
        }
        self.thread = thread
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        preconditionFailure("Use init(with:) instead.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setUpGradientBackground()
        setUpNavBarStyle()
        setNavBarTitle("Edit Group")
        let backButton = UIBarButtonItem(title: "Back", style: .plain, target: nil, action: nil)
        backButton.tintColor = Colors.text
        navigationItem.backBarButtonItem = backButton
        func getDisplayName(for publicKey: String) -> String {
            return UserDisplayNameUtilities.getPrivateChatDisplayName(for: publicKey) ?? publicKey
        }
        members = GroupUtilities.getClosedGroupMembers(thread).sorted { getDisplayName(for: $0) < getDisplayName(for: $1) }
        setUpViewHierarchy()
        updateNavigationBarButtons()
        name = thread.groupModel.groupName!
    }

    private func setUpViewHierarchy() {
        // Group name container
        groupNameLabel.text = thread.groupModel.groupName
        let groupNameContainer = UIView()
        groupNameContainer.addSubview(groupNameLabel)
        groupNameLabel.pin(to: groupNameContainer)
        groupNameContainer.addSubview(groupNameTextField)
        groupNameTextField.pin(to: groupNameContainer)
        groupNameContainer.set(.height, to: 40)
        groupNameTextField.alpha = 0
        // Top container
        let topContainer = UIView()
        topContainer.addSubview(groupNameContainer)
        groupNameContainer.center(in: topContainer)
        topContainer.set(.height, to: 40)
        let topContainerTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showEditGroupNameUI))
        topContainer.addGestureRecognizer(topContainerTapGestureRecognizer)
        // Members label
        let membersLabel = UILabel()
        membersLabel.textColor = Colors.text
        membersLabel.font = .systemFont(ofSize: Values.mediumFontSize)
        membersLabel.text = "Members"
        // Add members button
        let hasContactsToAdd = !Set(ContactUtilities.getAllContacts()).subtracting(self.members).isEmpty
        if (!hasContactsToAdd) {
            addMembersButton.isUserInteractionEnabled = false
            let disabledColor = Colors.text.withAlphaComponent(Values.unimportantElementOpacity)
            addMembersButton.layer.borderColor = disabledColor.cgColor
            addMembersButton.setTitleColor(disabledColor, for: UIControl.State.normal)
        }
        // Middle stack view
        let middleStackView = UIStackView(arrangedSubviews: [ membersLabel, addMembersButton ])
        middleStackView.axis = .horizontal
        middleStackView.alignment = .center
        middleStackView.layoutMargins = UIEdgeInsets(top: Values.smallSpacing, leading: Values.mediumSpacing, bottom: Values.smallSpacing, trailing: Values.mediumSpacing)
        middleStackView.isLayoutMarginsRelativeArrangement = true
        // Main stack view
        let mainStackView = UIStackView(arrangedSubviews: [
            UIView.vSpacer(Values.veryLargeSpacing),
            topContainer,
            UIView.vSpacer(Values.veryLargeSpacing),
            UIView.separator(),
            middleStackView,
            UIView.separator(),
            tableView
        ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        mainStackView.set(.width, to: UIScreen.main.bounds.width)
        // Scroll view
        let scrollView = UIScrollView()
        scrollView.showsVerticalScrollIndicator = false
        scrollView.addSubview(mainStackView)
        mainStackView.pin(to: scrollView)
        view.addSubview(scrollView)
        scrollView.pin(to: view)
        mainStackView.pin(.bottom, to: .bottom, of: view)
    }

    // MARK: Table View Data Source / Delegate
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return members.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "UserCell") as! UserCell
        let publicKey = members[indexPath.row]
        cell.publicKey = publicKey
        cell.update()
        return cell
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        let publicKey = members[indexPath.row]
        return publicKey != getUserHexEncodedPublicKey()
    }

    func tableView(_ tableView: UITableView, editActionsForRowAt indexPath: IndexPath) -> [UITableViewRowAction]? {
        let publicKey = members[indexPath.row]
        let removeAction = UITableViewRowAction(style: .destructive, title: "Remove") { [weak self] _, _ in
            guard let self = self, let index = self.members.firstIndex(of: publicKey) else { return }
            self.members.remove(at: index)
        }
        removeAction.backgroundColor = Colors.destructive
        return [ removeAction ]
    }

    // MARK: Updating
    private func updateNavigationBarButtons() {
        if isEditingGroupName {
            let cancelButton = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(handleCancelGroupNameEditingButtonTapped))
            cancelButton.tintColor = Colors.text
            navigationItem.leftBarButtonItem = cancelButton
        } else {
            navigationItem.leftBarButtonItem = nil
        }
        let doneButton = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(handleDoneButtonTapped))
        doneButton.tintColor = Colors.text
        navigationItem.rightBarButtonItem = doneButton
    }

    private func handleIsEditingGroupNameChanged() {
        updateNavigationBarButtons()
        UIView.animate(withDuration: 0.25) {
            self.groupNameLabel.alpha = self.isEditingGroupName ? 0 : 1
            self.groupNameTextField.alpha = self.isEditingGroupName ? 1 : 0
        }
        if isEditingGroupName {
            groupNameTextField.becomeFirstResponder()
        } else {
            groupNameTextField.resignFirstResponder()
        }
    }

    // MARK: Interaction
    @objc private func showEditGroupNameUI() {
        isEditingGroupName = true
    }

    @objc private func handleCancelGroupNameEditingButtonTapped() {
        isEditingGroupName = false
    }

    @objc private func handleDoneButtonTapped() {
        if isEditingGroupName {
            updateGroupName()
        } else {
            commitChanges()
        }
    }

    private func updateGroupName() {
        let name = groupNameTextField.text!.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !name.isEmpty else {
            return showError(title: NSLocalizedString("vc_create_closed_group_group_name_missing_error", comment: ""))
        }
        guard name.count < ClosedGroupsProtocol.maxNameSize else {
            return showError(title: NSLocalizedString("vc_create_closed_group_group_name_too_long_error", comment: ""))
        }
        isEditingGroupName = false
        self.name = name
        groupNameLabel.text = name
    }

    @objc private func addMembers() {
        let title = "Add Members"
        let userSelectionVC = UserSelectionVC(with: title, excluding: Set(members)) { [weak self] selectedUsers in
            guard let self = self else { return }
            var members = self.members
            members.append(contentsOf: selectedUsers)
            func getDisplayName(for publicKey: String) -> String {
                return UserDisplayNameUtilities.getPrivateChatDisplayName(for: publicKey) ?? publicKey
            }
            self.members = members.sorted { getDisplayName(for: $0) < getDisplayName(for: $1) }
            let hasContactsToAdd = !Set(ContactUtilities.getAllContacts()).subtracting(self.members).isEmpty
            self.addMembersButton.isUserInteractionEnabled = hasContactsToAdd
            let color = hasContactsToAdd ? Colors.accent : Colors.text.withAlphaComponent(Values.unimportantElementOpacity)
            self.addMembersButton.layer.borderColor = color.cgColor
            self.addMembersButton.setTitleColor(color, for: UIControl.State.normal)
        }
        navigationController!.pushViewController(userSelectionVC, animated: true, completion: nil)
    }

    private func commitChanges() {
        let popToConversationVC: (EditClosedGroupVC) -> Void = { editVC in
            if let conversationVC = editVC.navigationController!.viewControllers.first(where: { $0 is ConversationViewController }) {
                editVC.navigationController!.popToViewController(conversationVC, animated: true)
            } else {
                editVC.navigationController!.popViewController(animated: true)
            }
        }
        let groupID = thread.groupModel.groupId
        let groupPublicKey = LKGroupUtilities.getDecodedGroupID(groupID)
        let members = Set(self.members)
        let name = self.name
        guard members != Set(thread.groupModel.groupMemberIds) || name != thread.groupModel.groupName else {
            return popToConversationVC(self)
        }
        ModalActivityIndicatorViewController.present(fromViewController: navigationController!, canCancel: false) { [weak self] _ in
            try! Storage.writeSync { [weak self] transaction in
                ClosedGroupsProtocol.update(groupPublicKey, with: members, name: name, transaction: transaction).done(on: DispatchQueue.main) {
                    guard let self = self else { return }
                    self.dismiss(animated: true, completion: nil) // Dismiss the loader
                    popToConversationVC(self)
                }.catch(on: DispatchQueue.main) { error in
                    guard let self = self else { return }
                    self.dismiss(animated: true, completion: nil) // Dismiss the loader
                    self.showError(title: "Couldn't Update Group", message: "Please check your internet connection and try again.")
                }
            }
        }
    }

    // MARK: Convenience
    private func showError(title: String, message: String = "") {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil))
        presentAlert(alert)
    }
}
