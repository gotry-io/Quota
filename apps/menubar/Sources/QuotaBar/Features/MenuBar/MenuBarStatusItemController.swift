import AppKit
import Observation
import QuotaWire

/// Owns the menu-bar status items and the one panel they share.
@MainActor
final class MenuBarStatusItemController: NSObject {
  private let model: MenuBarViewModel
  private let panel: MenuBarPanelController
  private let statusBar = NSStatusBar.system
  private var items: [MenuBarStatusItemID: NSStatusItem] = [:]
  private var lastSpecs: [MenuBarStatusItemSpec] = []
  private var defaultsObserver: (any NSObjectProtocol)?
  private var tracking = false

  init(model: MenuBarViewModel) {
    self.model = model
    self.panel = MenuBarPanelController(model: model)
    super.init()
    panel.statusItemWindows = { [weak self] in
      Set(self?.items.values.compactMap(\.button?.window) ?? [])
    }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.reconcile()
      }
    }
    startTracking()
  }

  func invalidate() {
    if let defaultsObserver {
      NotificationCenter.default.removeObserver(defaultsObserver)
      self.defaultsObserver = nil
    }
    tracking = false
    panel.invalidate()
    for item in items.values {
      statusBar.removeStatusItem(item)
    }
    items.removeAll()
    lastSpecs = []
  }

  private func startTracking() {
    tracking = true
    withObservationTracking {
      _ = model.menuBarClock
      reconcile()
    } onChange: { [weak self] in
      Task { @MainActor in
        guard let self, self.tracking else { return }
        self.startTracking()
      }
    }
  }

  private func reconcile() {
    let prefs = MenuBarItemPreferences.load()
    let layout = prefs.layout(visibleProviders: ProviderDisplayOrder.enabledProviders())
    let specs = model.menuBarSpecs(style: prefs.style, layout: layout, now: model.menuBarClock)
    guard specs != lastSpecs else { return }

    let previousIDs = lastSpecs.map(\.id)
    let ids = specs.map(\.id)
    let identityChanged = ids != previousIDs
    lastSpecs = specs

    if identityChanged {
      let desired = Set(ids)
      for id in items.keys where !desired.contains(id) {
        if panel.anchorID == id {
          panel.close()
        }
        if let item = items.removeValue(forKey: id) {
          statusBar.removeStatusItem(item)
        }
      }
    }

    for spec in specs {
      let item = items[spec.id] ?? makeItem(id: spec.id)
      items[spec.id] = item
      apply(spec, to: item)
    }

    if identityChanged {
      reanchorPanelIfNeeded(specs: specs)
    } else {
      panel.repositionIfOpen()
    }
  }

  private func reanchorPanelIfNeeded(specs: [MenuBarStatusItemSpec]) {
    guard panel.isOpen else { return }
    if let anchorID = panel.anchorID, let item = items[anchorID], let button = item.button {
      panel.open(relativeTo: button, id: anchorID)
    } else if let first = specs.first, let item = items[first.id], let button = item.button {
      panel.open(relativeTo: button, id: first.id)
    } else {
      panel.close()
    }
  }

  private func makeItem(id: MenuBarStatusItemID) -> NSStatusItem {
    let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = id.autosaveName
    if let button = item.button {
      button.imageScaling = .scaleNone
      button.target = self
      button.action = #selector(clicked(_:))
      button.sendAction(on: [.leftMouseUp])
      button.setAccessibilityIdentifier(id.accessibilityIdentifier)
      button.setAccessibilityTitle("QuotaBar")
      button.identifier = NSUserInterfaceItemIdentifier(id.autosaveName)
    }
    return item
  }

  private func apply(_ spec: MenuBarStatusItemSpec, to item: NSStatusItem) {
    let image = MenuBarItemImage.make(spec.label)
    item.button?.image = image
    item.button?.imagePosition = .imageOnly
    item.button?.setAccessibilityLabel(spec.label.accessibilityLabel)
    item.isVisible = true
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    guard let id = items.first(where: { $0.value.button === sender })?.key else { return }
    panel.toggle(relativeTo: sender, id: id, focusProvider: id.focusProvider)
  }
}
