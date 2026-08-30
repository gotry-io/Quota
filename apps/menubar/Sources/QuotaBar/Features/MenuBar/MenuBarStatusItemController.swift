import AppKit
import Observation
import QuotaWire

/// Owns the menu-bar status items and the one panel they share.
@MainActor
final class MenuBarStatusItemController: NSObject {
  /// One physical status item. `index` is the autosave identity, set at creation and never
  /// changed: rewriting `autosaveName` would move the item on the bar.
  private struct Slot {
    let item: NSStatusItem
    let index: Int
    var id: MenuBarStatusItemID
  }

  private let model: MenuBarViewModel
  private let defaults: UserDefaults
  let panel: MenuBarPanelController
  private let statusBar = NSStatusBar.system
  private var slots: [Slot] = []
  private var lastSpecs: [MenuBarStatusItemSpec] = []
  private var defaultsObserver: (any NSObjectProtocol)?
  private var tracking = false

  init(model: MenuBarViewModel, defaults: UserDefaults = .standard) {
    self.model = model
    self.defaults = defaults
    self.panel = MenuBarPanelController(model: model)
    super.init()
    panel.statusItemWindows = { [weak self] in
      Set(self?.slots.compactMap(\.item.button?.window) ?? [])
    }
    defaultsObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification,
      object: defaults,
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
    for slot in slots {
      statusBar.removeStatusItem(slot.item)
    }
    slots.removeAll()
    lastSpecs = []
  }

  var statusItemIDs: [MenuBarStatusItemID] {
    slots.map(\.id)
  }

  func button(for id: MenuBarStatusItemID) -> NSStatusBarButton? {
    slots.first { $0.id == id }?.item.button
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

  func reconcile() {
    let prefs = MenuBarItemPreferences.load(from: defaults)
    let layout = prefs.layout(
      visibleProviders: ProviderDisplayOrder.enabledProviders(defaults: defaults)
    )
    let specs = model.menuBarSpecs(style: prefs.style, layout: layout, now: model.menuBarClock)
    guard specs != lastSpecs else { return }
    lastSpecs = specs

    // A reading still on the bar keeps its item; the item under an open panel gets first pick
    // of the rest; the rest keep bar order. Whatever stays in `available` is not needed.
    var available = slots
    var assigned = [Slot?](repeating: nil, count: specs.count)
    for (index, spec) in specs.enumerated() {
      if let match = available.firstIndex(where: { $0.id == spec.id }) {
        assigned[index] = available.remove(at: match)
      }
    }
    if panel.isOpen, let anchor = available.firstIndex(where: { $0.id == panel.anchorID }) {
      available.insert(available.remove(at: anchor), at: 0)
    }
    for index in assigned.indices where assigned[index] == nil && !available.isEmpty {
      assigned[index] = available.removeFirst()
    }

    var usedIndexes = Set(slots.map(\.index))
    var next: [Slot] = []
    for (spec, slot) in zip(specs, assigned) {
      var slot = slot ?? makeSlot(id: spec.id, used: &usedIndexes)
      slot.id = spec.id
      next.append(slot)
    }
    slots = next

    // Images change after the panel has followed, because a new image resizes the item's
    // window in place before the bar moves it, and the panel must not read that frame. Unused
    // items go last, after `open` has un-highlighted the one the panel is leaving.
    followOpenPanel()
    for (spec, slot) in zip(specs, slots) {
      apply(spec, to: slot.item)
    }
    for slot in available {
      statusBar.removeStatusItem(slot.item)
    }
  }

  /// The open panel stays with the item it was under, whatever that item now shows; if that
  /// item is gone, it moves to the first one.
  private func followOpenPanel() {
    guard panel.isOpen else { return }
    if let button = panel.anchorButton,
      let slot = slots.first(where: { $0.item.button === button })
    {
      panel.open(relativeTo: button, id: slot.id)
    } else if let first = slots.first, let button = first.item.button {
      panel.open(relativeTo: button, id: first.id)
    }
  }

  private func makeSlot(id: MenuBarStatusItemID, used: inout Set<Int>) -> Slot {
    var index = 0
    while used.contains(index) {
      index += 1
    }
    used.insert(index)
    let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
    item.autosaveName = "quotabar-item-\(index)"
    if let button = item.button {
      button.imageScaling = .scaleNone
      button.target = self
      button.action = #selector(clicked(_:))
      button.sendAction(on: [.leftMouseUp])
      button.setAccessibilityTitle("QuotaBar")
    }
    return Slot(item: item, index: index, id: id)
  }

  private func apply(_ spec: MenuBarStatusItemSpec, to item: NSStatusItem) {
    item.button?.image = MenuBarItemImage.make(spec.label)
    item.button?.imagePosition = .imageOnly
    item.button?.setAccessibilityIdentifier(spec.id.accessibilityIdentifier)
    item.button?.setAccessibilityLabel(spec.label.accessibilityLabel)
    item.isVisible = true
  }

  @objc private func clicked(_ sender: NSStatusBarButton) {
    guard let id = slots.first(where: { $0.item.button === sender })?.id else { return }
    panel.toggle(relativeTo: sender, id: id, focusProvider: id.focusProvider)
  }
}
