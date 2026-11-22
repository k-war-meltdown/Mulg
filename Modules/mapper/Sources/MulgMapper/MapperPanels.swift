#if canImport(UIKit) && !os(watchOS)
import MulgContracts
import MulgEngine
import MulgKeymaps
import UIKit

// The mapper's panels. Each one is drawn from the `MapperSession` and sends what the player does back to it.

// MARK: - Toolbar

/// The bar at the top: profile menu, undo and redo, layers, Cancel and Save.
final class MapperToolbarView: UIVisualEffectView {
    private let profileButton = MapperStyle.makeButton(title: "Profile", role: .tinted)
    private let undoButton = MapperStyle.makeButton(symbol: "arrow.uturn.backward")
    private let redoButton = MapperStyle.makeButton(symbol: "arrow.uturn.forward")
    private let layersButton = MapperStyle.makeButton(symbol: "square.3.layers.3d")
    private let cancelButton = MapperStyle.makeButton(title: "Cancel", symbol: "xmark", role: .tinted)
    private let saveButton = MapperStyle.makeButton(title: "Save", symbol: "checkmark", role: .primary)
    private let stack = UIStackView()
    private weak var session: MapperSession?

    init(session: MapperSession) {
        self.session = session
        super.init(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor

        stack.axis = .horizontal
        stack.spacing = 6
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [profileButton, undoButton, redoButton, layersButton, spacer, cancelButton, saveButton] {
            stack.addArrangedSubview(view)
        }
        contentView.addSubview(stack)

        // A long profile name is cut short rather than pushing the other buttons off the bar.
        profileButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profileButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        profileButton.showsMenuAsPrimaryAction = true
        layersButton.showsMenuAsPrimaryAction = true
        undoButton.addAction(UIAction { [weak session] _ in session?.undo() }, for: .primaryActionTriggered)
        redoButton.addAction(UIAction { [weak session] _ in session?.redo() }, for: .primaryActionTriggered)
        cancelButton.accessibilityLabel = "Cancel"
        saveButton.accessibilityLabel = "Save"
        cancelButton.addAction(UIAction { [weak session] _ in session?.requestFinish(save: false) }, for: .primaryActionTriggered)
        saveButton.addAction(UIAction { [weak session] _ in session?.requestFinish(save: true) }, for: .primaryActionTriggered)
        undoButton.accessibilityLabel = "Undo"
        redoButton.accessibilityLabel = "Redo"
        layersButton.accessibilityLabel = "Layers"
        profileButton.accessibilityLabel = "Profiles"
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// On a narrow window Cancel and Save show only their symbols.
    private var compact = false

    private func setCompact(_ value: Bool) {
        guard value != compact else { return }
        compact = value
        for (button, title, symbol) in [(cancelButton, "Cancel", "xmark"), (saveButton, "Save", "checkmark")] {
            var configuration = button.configuration
            configuration?.title = value ? nil : title
            configuration?.image = MapperStyle.symbol(symbol)
            configuration?.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: value ? 9 : 12, bottom: 7, trailing: value ? 9 : 12)
            button.configuration = configuration
        }
    }

    /// The width the bar wants at most; the canvas gives it what it can.
    func size(fitting width: CGFloat) -> CGSize {
        setCompact(width < 640)
        let target = min(width, 760)
        let height = stack.systemLayoutSizeFitting(CGSize(width: target, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel).height
        return CGSize(width: target, height: max(height, 48))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = contentView.bounds
    }

    func update() {
        guard let session else { return }
        var configuration = profileButton.configuration
        configuration?.title = session.profile
        configuration?.image = MapperStyle.symbol("chevron.down", size: 11)
        configuration?.imagePlacement = .trailing
        configuration?.titleLineBreakMode = .byTruncatingMiddle
        profileButton.configuration = configuration
        profileButton.menu = makeProfileMenu(session)
        undoButton.isEnabled = session.canUndo
        redoButton.isEnabled = session.canRedo
        layersButton.menu = makeLayerMenu(session)
        layersButton.tintColor = session.currentLayer > 0 ? MapperStyle.selection : .white
    }

    private func makeProfileMenu(_ session: MapperSession) -> UIMenu {
        let profiles = session.profiles.map { profile in
            UIAction(title: profile.name,
                     subtitle: profile.controlCount == 1 ? "1 control" : "\(profile.controlCount) controls",
                     state: profile.name == session.profile ? .on : .off) { [weak session] _ in
                session?.requestProfile(profile.name)
            }
        }
        let manage = UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "Save as new profile…", image: UIImage(systemName: "doc.on.doc")) { [weak session] _ in
                session?.requestCopyAsNewProfile()
            },
            UIAction(title: "New blank profile…", image: UIImage(systemName: "plus.square")) { [weak session] _ in
                session?.requestNewBlankProfile()
            }
        ])
        return UIMenu(title: "Profiles", children: [UIMenu(title: "", options: .displayInline, children: profiles), manage])
    }

    private func makeLayerMenu(_ session: MapperSession) -> UIMenu {
        let header = UIAction(title: session.layerTitle, attributes: .disabled) { _ in }
        let steps = UIMenu(title: "", options: .displayInline, children: [
            UIAction(title: "Previous layer", image: UIImage(systemName: "chevron.up"),
                     attributes: session.layerCount == 0 ? .disabled : []) { [weak session] _ in session?.showLayer(offset: -1) },
            UIAction(title: "Next layer", image: UIImage(systemName: "chevron.down"),
                     attributes: session.layerCount == 0 ? .disabled : []) { [weak session] _ in session?.showLayer(offset: 1) },
            UIAction(title: "New layer (controls while a key is held)", image: UIImage(systemName: "plus.square.on.square")) {
                [weak session] _ in session?.addLayer()
            }
        ])
        return UIMenu(title: "Layers", children: [header, steps])
    }
}

// MARK: - Inspector

/// The panel next to the selected control: what it is bound to and the few things to change about it.
final class MapperInspectorView: UIVisualEffectView {
    private let titleLabel = MapperStyle.makeLabel(size: 14, weight: .bold)
    private let bindingChip = MapperStyle.makeLabel(size: 13, weight: .heavy, color: .black, alignment: .center)
    private let detailLabel = MapperStyle.makeLabel(size: 12, color: UIColor.white.withAlphaComponent(0.8), lines: 0)
    private let directions = UIStackView()
    private let mouseAim = MapperStyle.makeButton(title: "Mouse aim while held", role: .tinted)
    private let tools = UIStackView()
    private let ending = UIStackView()
    private let content = UIStackView()
    private let smaller = MapperStyle.makeButton(symbol: "minus")
    private let larger = MapperStyle.makeButton(symbol: "plus")
    private let leftClick = MapperStyle.makeButton(title: "Left click", symbol: "computermouse", role: .tinted)
    private let mode = MapperStyle.makeButton(title: "", role: .tinted)
    private let delete = MapperStyle.makeButton(symbol: "trash", role: .destructive)
    private let done = MapperStyle.makeButton(title: "Done", symbol: "checkmark", role: .primary)
    private weak var session: MapperSession?
    private var shown: MapperSession.Inspector?

    init(session: MapperSession) {
        self.session = session
        super.init(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor

        bindingChip.backgroundColor = .white
        bindingChip.layer.cornerRadius = 9
        bindingChip.clipsToBounds = true
        let header = UIStackView(arrangedSubviews: [titleLabel, UIView(), bindingChip])
        header.alignment = .center
        header.spacing = 8
        directions.axis = .horizontal
        directions.spacing = 4
        directions.distribution = .fillEqually
        for row in [tools, ending] {
            row.axis = .horizontal
            row.spacing = 6
            row.alignment = .center
        }
        content.axis = .vertical
        content.spacing = 8
        content.isLayoutMarginsRelativeArrangement = true
        content.layoutMargins = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for view in [header, detailLabel, directions, mouseAim, tools, ending] { content.addArrangedSubview(view) }
        contentView.addSubview(content)
        bindingChip.contentMode = .center

        smaller.addAction(UIAction { [weak session] _ in session?.resizeSelected(larger: false) }, for: .primaryActionTriggered)
        larger.addAction(UIAction { [weak session] _ in session?.resizeSelected(larger: true) }, for: .primaryActionTriggered)
        mouseAim.addAction(UIAction { [weak session] _ in session?.toggleSelectedMouseAim() }, for: .primaryActionTriggered)
        mouseAim.toolTip = "Move this button's held touch with the mouse for attacks or skills that aim by dragging their button."
        leftClick.addAction(UIAction { [weak session] _ in session?.bindLeftClick() }, for: .primaryActionTriggered)
        mode.addAction(UIAction { [weak session] _ in session?.toggleSelectedMode() }, for: .primaryActionTriggered)
        delete.addAction(UIAction { [weak session] _ in session?.deleteSelected() }, for: .primaryActionTriggered)
        done.addAction(UIAction { [weak session] _ in session?.deselect() }, for: .primaryActionTriggered)
        for button in [leftClick, mode] {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.configuration?.titleLineBreakMode = .byTruncatingTail
        }
        smaller.accessibilityLabel = "Smaller"
        larger.accessibilityLabel = "Larger"
        delete.accessibilityLabel = "Delete control"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ inspector: MapperSession.Inspector) {
        guard inspector != shown else { return }
        shown = inspector
        titleLabel.text = inspector.title
        bindingChip.text = "  \(inspector.binding)  "
        bindingChip.backgroundColor = inspector.isAwaitingKey ? MapperStyle.selection : .white
        detailLabel.text = inspector.detail
        mouseAim.isHidden = inspector.mouseAim == nil
        mouseAim.configuration?.image = MapperStyle.symbol(inspector.mouseAim == true ? "checkmark.circle.fill" : "circle", size: 13)
        mouseAim.accessibilityValue = inspector.mouseAim == true ? "On" : "Off"
        directions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        directions.isHidden = inspector.directions.isEmpty
        for (part, label) in inspector.directions {
            let button = MapperStyle.makeButton(title: label, role: inspector.focusedPart == part ? .primary : .tinted)
            button.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
            button.addAction(UIAction { [weak session] _ in session?.select(inspector.id, part: part) }, for: .primaryActionTriggered)
            directions.addArrangedSubview(button)
        }
        tools.arrangedSubviews.forEach { $0.removeFromSuperview() }
        tools.addArrangedSubview(smaller)
        tools.addArrangedSubview(larger)
        if inspector.offersLeftClick { tools.addArrangedSubview(leftClick) }
        if let toggle = inspector.modeToggle {
            var configuration = mode.configuration
            configuration?.title = toggle.title
            configuration?.image = MapperStyle.symbol(toggle.isOn ? "checkmark.circle.fill" : "circle", size: 13)
            mode.configuration = configuration
            mode.accessibilityHint = toggle.help
            mode.accessibilityValue = toggle.isOn ? "On" : "Off"
            mode.toolTip = toggle.help
            tools.addArrangedSubview(mode)
        }
        tools.addArrangedSubview(UIView())
        ending.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ending.addArrangedSubview(delete)
        ending.addArrangedSubview(UIView())
        ending.addArrangedSubview(done)
        setNeedsLayout()
    }

    func size(fitting width: CGFloat) -> CGSize {
        let target = min(width, 360)
        let fitted = content.systemLayoutSizeFitting(CGSize(width: target, height: UIView.layoutFittingCompressedSize.height),
                                                     withHorizontalFittingPriority: .required,
                                                     verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: target, height: fitted.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.frame = contentView.bounds
    }
}

// MARK: - Picker

/// The menu a left click on empty space opens: what do you want to place here?
final class MapperPickerView: UIVisualEffectView {
    private let stack = UIStackView()

    init(session: MapperSession, point: CGPoint) {
        super.init(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
        stack.axis = .vertical
        stack.spacing = 2
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let header = MapperStyle.makeLabel(size: 11, weight: .semibold, color: UIColor.white.withAlphaComponent(0.65))
        header.text = "ADD A CONTROL HERE"
        header.textAlignment = .natural
        stack.addArrangedSubview(header)
        for tool in MapperTool.allCases {
            var configuration = UIButton.Configuration.plain()
            configuration.title = tool.title
            configuration.subtitle = tool.subtitle
            configuration.image = MapperStyle.symbol(tool.symbol, size: 20)
            configuration.imagePadding = 12
            configuration.baseForegroundColor = .white
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in MapperStyle.color(for: tool) }
            configuration.titleAlignment = .leading
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 14)
            let button = UIButton(configuration: configuration)
            button.contentHorizontalAlignment = .leading
            button.addAction(UIAction { [weak session] _ in session?.place(tool, at: point) }, for: .primaryActionTriggered)
            button.accessibilityLabel = "\(tool.title). \(tool.subtitle)"
            stack.addArrangedSubview(button)
        }
        contentView.addSubview(stack)
        let size = stack.systemLayoutSizeFitting(CGSize(width: 250, height: UIView.layoutFittingCompressedSize.height),
                                                 withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
        preferredSize = CGSize(width: max(size.width, 250), height: size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private(set) var preferredSize = CGSize(width: 250, height: 220)

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = contentView.bounds
    }
}

// MARK: - Prompt

/// A question over a dimmed canvas: naming a profile, or whether to keep unsaved changes.
final class MapperPromptView: UIView, UITextFieldDelegate {
    private let card = MapperStyle.makeCard(cornerRadius: 18)
    private let titleLabel = MapperStyle.makeLabel(size: 16, weight: .bold, lines: 0, alignment: .center)
    private let bodyLabel = MapperStyle.makeLabel(size: 13, color: UIColor.white.withAlphaComponent(0.8), lines: 0, alignment: .center)
    private let errorLabel = MapperStyle.makeLabel(size: 12, weight: .semibold, color: .systemRed, lines: 0, alignment: .center)
    private let field = UITextField()
    private let buttons = UIStackView()
    private let stack = UIStackView()
    private weak var session: MapperSession?
    private var shownPrompt: MapperSession.Prompt = .none

    init(session: MapperSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.4)
        field.borderStyle = .roundedRect
        field.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        field.textColor = .black
        field.font = .systemFont(ofSize: 15)
        field.clearButtonMode = .whileEditing
        field.returnKeyType = .done
        field.autocorrectionType = .no
        field.delegate = self
        field.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillEqually
        stack.axis = .vertical
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [titleLabel, bodyLabel, field, errorLabel, buttons] { stack.addArrangedSubview(view) }
        card.contentView.addSubview(stack)
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ prompt: MapperSession.Prompt, message: MapperSession.Message?) {
        guard let session else { return }
        errorLabel.text = message?.isError == true ? message?.text : nil
        errorLabel.isHidden = errorLabel.text == nil
        setNeedsLayout()
        if prompt == shownPrompt { return }
        shownPrompt = prompt
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        field.isHidden = true
        bodyLabel.isHidden = false
        func add(_ title: String, role: MapperStyle.Role, _ action: @escaping () -> Void) {
            let button = MapperStyle.makeButton(title: title, role: role)
            button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
            buttons.addArrangedSubview(button)
        }
        switch prompt {
        case .naming(let kind):
            titleLabel.text = kind == .copyOfDraft ? "Save as a new profile" : "New blank profile"
            bodyLabel.text = kind == .copyOfDraft
                ? "Your controls are saved under this name. “\(session.profile)” stays as it is."
                : "Starts with no controls. Name it so you can find it later."
            field.isHidden = false
            field.text = session.suggestedName
            field.placeholder = "Profile name"
            add("Cancel", role: .tinted) { [weak session] in session?.cancelPrompt() }
            add(kind == .copyOfDraft ? "Save" : "Create", role: .primary) { [weak self] in self?.submit() }
            DispatchQueue.main.async { [weak self] in
                self?.field.becomeFirstResponder()
                self?.field.selectAll(nil)
            }
        case .confirmDiscard:
            titleLabel.text = "Discard your changes?"
            bodyLabel.text = "“\(session.profile)” has changes you haven’t saved."
            add("Keep editing", role: .tinted) { [weak session] in session?.cancelPrompt() }
            add("Discard", role: .destructive) { [weak session] in session?.confirmDiscard() }
        case .confirmLeave(let leave):
            titleLabel.text = "Save changes to “\(session.profile)”?"
            switch leave {
            case .profile(let name): bodyLabel.text = "Before switching to “\(name)”."
            case .newBlank(let name): bodyLabel.text = "Before creating “\(name)”."
            }
            add("Cancel", role: .tinted) { [weak session] in session?.cancelPrompt() }
            add("Don’t save", role: .destructive) { [weak session] in session?.confirmLeave(save: false) }
            add("Save", role: .primary) { [weak session] in session?.confirmLeave(save: true) }
        case .none, .picker:
            break
        }
        setNeedsLayout()
    }

    private func submit() {
        session?.submitName(field.text ?? "")
    }

    /// Takes the keyboard back from the name field when the question goes away.
    func dismiss() {
        field.resignFirstResponder()
    }

    // Escape cancels the question, also while the name field has the keyboard (the field would
    // otherwise swallow it).
    override var canBecomeFirstResponder: Bool { false }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(action: #selector(escapePressed), input: UIKeyCommand.inputEscape)
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    @objc private func escapePressed() {
        session?.cancelPrompt()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = min(bounds.width - 32, 380)
        let fitted = stack.systemLayoutSizeFitting(CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                                                   withHorizontalFittingPriority: .required,
                                                   verticalFittingPriority: .fittingSizeLevel)
        card.frame = CGRect(x: (bounds.width - width) / 2, y: max((bounds.height - fitted.height) / 2 - 20, 12),
                            width: width, height: fitted.height)
        stack.frame = card.contentView.bounds
    }

    /// Clicking the dimmed area does nothing: a question is answered with its buttons.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        super.hitTest(point, with: event) ?? self
    }
}

// MARK: - Tip and message

/// A one-line capsule: the tip at the bottom, or a message (saved, failed) under the toolbar.
final class MapperCapsuleView: UIVisualEffectView {
    private let label = MapperStyle.makeLabel(size: 13, weight: .medium, alignment: .center)
    private let icon = UIImageView()

    init() {
        super.init(effect: UIBlurEffect(style: .systemChromeMaterialDark))
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        label.numberOfLines = 2
        contentView.addSubview(icon)
        contentView.addSubview(label)
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String, symbol: String? = nil, tint: UIColor = .white) {
        label.text = text
        icon.image = symbol.flatMap { MapperStyle.symbol($0, size: 14) }
        icon.tintColor = tint
        icon.isHidden = symbol == nil
        setNeedsLayout()
    }

    func size(fitting width: CGFloat) -> CGSize {
        let iconWidth: CGFloat = icon.isHidden ? 0 : 22
        let text = label.sizeThatFits(CGSize(width: width - 32 - iconWidth, height: .greatestFiniteMagnitude))
        return CGSize(width: min(text.width + 28 + iconWidth, width), height: max(text.height + 14, 30))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let iconWidth: CGFloat = icon.isHidden ? 0 : 22
        icon.frame = CGRect(x: 12, y: (bounds.height - 18) / 2, width: 18, height: 18)
        label.frame = CGRect(x: 14 + iconWidth, y: 0, width: bounds.width - 28 - iconWidth, height: bounds.height)
    }
}
#endif
