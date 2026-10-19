//
//  QuickActionsView.swift
//  Kit
//
//  Created by didi on 2026/10/18.
//  Using Swift 5.0
//  Running on macOS 10.15+
//

import Cocoa

public class QuickActionButton: NSButton {
    private let item: QuickActionItem
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    
    private let iconImageView: NSImageView = {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
    
    private let titleLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()
    
    private let contentStack: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    public init(item: QuickActionItem) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 26))
        
        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true
        self.layer?.cornerRadius = Constants.Popup.radius
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.title = ""
        self.toolTip = item.toolTip
        self.target = self
        self.action = #selector(self.buttonClicked)
        
        self.setupViews()
        self.updateState()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupViews() {
        self.addSubview(self.contentStack)
        
        self.iconImageView.image = iconFromSymbol(name: self.item.iconName, scale: .small)
        self.titleLabel.stringValue = self.item.title
        
        self.contentStack.addArrangedSubview(self.iconImageView)
        self.contentStack.addArrangedSubview(self.titleLabel)
        
        NSLayoutConstraint.activate([
            self.iconImageView.widthAnchor.constraint(equalToConstant: 14),
            self.iconImageView.heightAnchor.constraint(equalToConstant: 14),
            self.contentStack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            self.contentStack.leadingAnchor.constraint(greaterThanOrEqualTo: self.leadingAnchor, constant: 2),
            self.contentStack.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -2),
            self.contentStack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
            self.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
    
    public func updateState() {
        self.isEnabled = self.item.isAvailable()
        self.alphaValue = self.isEnabled ? 1 : 0.5
        let active = self.item.isEnabled()
        
        if active {
            self.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            self.iconImageView.contentTintColor = .white
            self.titleLabel.textColor = .white
        } else {
            let bgAlpha: CGFloat = self.isHovered ? (isDarkMode ? 0.16 : 0.10) : (isDarkMode ? 0.08 : 0.05)
            self.layer?.backgroundColor = (isDarkMode ? NSColor.white : NSColor.black).withAlphaComponent(bgAlpha).cgColor
            self.iconImageView.contentTintColor = isDarkMode ? .white : .labelColor
            self.titleLabel.textColor = isDarkMode ? .white : .labelColor
        }
    }
    
    @objc private func buttonClicked() {
        guard self.item.isAvailable() else { return }
        self.item.action(self.item) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateState()
            }
        }
    }
    
    public override func hitTest(_ point: NSPoint) -> NSView? {
        // AppKit supplies superview coordinates. Keep child labels/images from taking the click.
        return super.hitTest(point) == nil ? nil : self
    }
    
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = self.trackingArea {
            self.removeTrackingArea(area)
        }
        let area = NSTrackingArea(rect: self.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        self.addTrackingArea(area)
        self.trackingArea = area
    }
    
    public override func mouseEntered(with event: NSEvent) {
        self.isHovered = true
        self.updateState()
    }
    
    public override func mouseExited(with event: NSEvent) {
        self.isHovered = false
        self.updateState()
    }
}

public class QuickActionsView: NSView {
    public static let viewHeight: CGFloat = 38
    
    private let stackView: NSStackView = {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    
    private let separatorLine: NSView = {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        return line
    }()
    
    private var actionButtons: [QuickActionButton] = []
    
    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Constants.Popup.width, height: QuickActionsView.viewHeight))
        // PopupView sets this container's frame; only its children use Auto Layout.
        self.translatesAutoresizingMaskIntoConstraints = true
        self.setupViews()
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.handleActionsChanged), name: .quickActionsChanged, object: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupViews() {
        self.addSubview(self.stackView)
        self.addSubview(self.separatorLine)
        
        self.separatorLine.layer?.backgroundColor = (isDarkMode ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)).cgColor
        
        NSLayoutConstraint.activate([
            self.stackView.topAnchor.constraint(equalTo: self.topAnchor, constant: 4),
            self.stackView.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Constants.Popup.margins),
            self.stackView.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Constants.Popup.margins),
            self.stackView.heightAnchor.constraint(equalToConstant: 26),
            
            self.separatorLine.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -1),
            self.separatorLine.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: Constants.Popup.margins),
            self.separatorLine.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -Constants.Popup.margins),
            self.separatorLine.heightAnchor.constraint(equalToConstant: 1)
        ])
        
        self.reloadButtons()
    }
    
    public func reloadButtons() {
        self.actionButtons.forEach { $0.removeFromSuperview() }
        self.actionButtons.removeAll()
        
        let actions = QuickActionsManager.shared.actions
        for item in actions {
            let button = QuickActionButton(item: item)
            self.actionButtons.append(button)
            self.stackView.addArrangedSubview(button)
        }
    }
    
    @objc private func handleActionsChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.actionButtons.forEach { $0.updateState() }
        }
    }
    
    public override func updateLayer() {
        super.updateLayer()
        self.separatorLine.layer?.backgroundColor = (isDarkMode ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)).cgColor
        self.actionButtons.forEach { $0.updateState() }
    }
}
