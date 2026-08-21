import SwiftUI
import AppKit

@MainActor
enum MenuBuilder {
    private static let menuWidth: CGFloat = 320

    /// Fill a menu with the current state of the app.
    ///
    /// The menu itself is kept and refilled rather than replaced. Handing the
    /// status item a new menu while the old one is open takes the open one down
    /// with it, which on a thirty-second refresh means the menu closing under
    /// whoever is reading it.
    static func populate(_ menu: NSMenu, appState: AppState) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let actions = MenuActions.shared

        let headerItem = NSMenuItem()
        let headerView = NSHostingView(rootView: MenuHeaderView(appState: appState))
        headerView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 46)
        headerItem.view = headerView
        menu.addItem(headerItem)

        // Say plainly when the hub is out of the picture. These readings are live,
        // but they arrived by a different route and they carry no history and no
        // alerts — presenting them as business as usual would be a lie of omission.
        // Chosen and imposed are both worth saying, and they are not the same news:
        // one is a mode the user turned on, the other is something breaking.
        switch appState.dataSource {
        case .hub:
            break
        case .ssh(let reason):
            menu.addItem(createInfoItem("⚠︎ Merkeze ulaşılamıyor — SSH", subtext: reason))
            menu.addItem(NSMenuItem.separator())
        case .sshDirect:
            menu.addItem(createInfoItem(
                "Doğrudan SSH — merkez atlandı",
                subtext: "Her makineden doğrudan okunuyor. Geçmiş ve uyarılar kullanılamaz."
            ))
            menu.addItem(NSMenuItem.separator())
        }

        if !appState.actionableAlerts.isEmpty {
            menu.addItem(createAlertsSubmenu(alerts: appState.actionableAlerts, systems: appState.selectedInstanceSystems))
            menu.addItem(NSMenuItem.separator())
        }

        if appState.instances.isEmpty && appState.sshTargets.isEmpty {
            menu.addItem(createInfoItem("Merkez Yapılandırılmamış", subtext: "Bir merkez veya SSH hedefi eklemek için Ayarlar’ı açın"))
        } else if appState.isLoading {
            let item = NSMenuItem(title: "Yükleniyor…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if appState.selectedInstanceSystems.isEmpty {
            menu.addItem(createInfoItem(
                "Sistem Bulunamadı",
                subtext: appState.dataSource.isHub
                    ? "Merkez yapılandırmasını kontrol edin"
                    : "SSH hedeflerini kontrol edin"
            ))
        } else {
            for system in appState.selectedInstanceSystems.prefix(15) {
                let item = createSystemItem(for: system, appState: appState)
                menu.addItem(item)
            }

            if appState.selectedInstanceSystems.count > 15 {
                let more = NSMenuItem(title: "+\(appState.selectedInstanceSystems.count - 15) sistem daha", action: nil, keyEquivalent: "")
                more.isEnabled = false
                more.attributedTitle = NSAttributedString(
                    string: "+\(appState.selectedInstanceSystems.count - 15) sistem daha",
                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]
                )
                menu.addItem(more)
            }
        }

        menu.addItem(NSMenuItem.separator())

        if appState.instances.count > 1 {
            menu.addItem(createHubSwitcherSubmenu(appState: appState))
        }

        let settingsItem = NSMenuItem(
            title: "Ayarlar…",
            action: #selector(MenuActions.openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = actions
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        settingsItem.image?.size = NSSize(width: 14, height: 14)
        menu.addItem(settingsItem)

        menu.addItem(createRefreshItem(actions: actions))
        menu.addItem(createSSHDirectItem())

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "BeszelBar’dan Çık",
            action: #selector(MenuActions.quit),
            keyEquivalent: "q"
        )
        quitItem.target = MenuActions.shared
        menu.addItem(quitItem)
    }

    /// Refreshing is something you do *to* the menu you are looking at, so the
    /// menu stays up and says what it is doing instead.
    private static func createRefreshItem(actions: MenuActions) -> NSMenuItem {
        // The view takes the mouse, but ⌘R still goes through the item, so the
        // action stays wired. A key equivalent closing the menu is what a key
        // equivalent is expected to do; a click is not.
        let item = NSMenuItem(
            title: "Şimdi Yenile",
            action: #selector(MenuActions.refreshNow),
            keyEquivalent: "r"
        )
        item.target = actions
        item.view = MenuActionRow(
            width: menuWidth,
            content: {
                let appState = AppState.shared
                return MenuActionRow.Content(
                    title: appState.isLoading ? "Yenileniyor…" : "Şimdi Yenile",
                    symbol: "arrow.clockwise",
                    isEnabled: !appState.isLoading
                )
            },
            onClick: { AppState.shared.loadSystems() }
        )
        return item
    }

    /// The switch between "ask the hub" and "ask the machines".
    ///
    /// A checkmark rather than a button that reads one way and behaves another:
    /// the row has to say which source is live right now, not merely what clicking
    /// it would do. Flipping it leaves the menu open, because the whole point of
    /// flipping it is to see what the other source says. Without a target to read
    /// it is inert and says why — a switch that appears to do nothing is worse
    /// than one that explains itself.
    private static func createSSHDirectItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuActionRow(
            width: menuWidth,
            content: {
                let appState = AppState.shared
                let toolTip: String
                if appState.sshTargets.isEmpty {
                    toolTip = "Önce Ayarlar → SSH bölümünden bir makine ekleyin."
                } else if appState.sshDirectModeEnabled {
                    toolTip = "Her makine SSH üzerinden okunuyor. Merkezle bağlantı kurulmuyor."
                } else {
                    toolTip = "Merkeze sormak yerine her makineyi SSH üzerinden okuyun."
                }

                return MenuActionRow.Content(
                    title: "Doğrudan SSH Modu",
                    symbol: "terminal",
                    isChecked: appState.sshDirectModeEnabled,
                    isEnabled: !appState.sshTargets.isEmpty,
                    toolTip: toolTip
                )
            },
            onClick: {
                let appState = AppState.shared
                guard !appState.sshTargets.isEmpty else { return }
                appState.sshDirectModeEnabled.toggle()
            }
        )
        return item
    }

    private static func createHubSwitcherSubmenu(appState: AppState) -> NSMenuItem {
        let item = NSMenuItem(title: "Merkez Değiştir", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)
        item.image?.size = NSSize(width: 14, height: 14)

        let submenu = NSMenu()
        for instance in appState.instances {
            let hubItem = NSMenuItem(
                title: instance.name.isEmpty ? instance.url : instance.name,
                action: #selector(MenuActions.switchHub(_:)),
                keyEquivalent: ""
            )
            hubItem.target = MenuActions.shared
            hubItem.representedObject = instance.id

            if instance.id == appState.selectedInstance?.id {
                hubItem.state = .on
            }

            submenu.addItem(hubItem)
        }

        item.submenu = submenu
        return item
    }

    private static func createAlertsSubmenu(alerts: [AlertRecord], systems: [SystemRecord]) -> NSMenuItem {
        let item = NSMenuItem(title: "Uyarılar (\(alerts.count))", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        item.image?.size = NSSize(width: 14, height: 14)
        item.image?.isTemplate = false

        let submenu = NSMenu()

        for alert in alerts.prefix(10) {
            let systemName = systems.first(where: { $0.id == alert.system })?.name ?? alert.system ?? "Bilinmiyor"
            let alertItem = NSMenuItem()

            let view = NSHostingView(rootView: AlertMenuRowView(alert: alert, systemName: systemName))
            view.frame = NSRect(x: 0, y: 0, width: menuWidth - 20, height: 44)
            alertItem.view = view

            submenu.addItem(alertItem)
        }

        if alerts.count > 10 {
            submenu.addItem(NSMenuItem.separator())
            let moreItem = NSMenuItem(title: "+\(alerts.count - 10) uyarı daha", action: nil, keyEquivalent: "")
            moreItem.isEnabled = false
            submenu.addItem(moreItem)
        }

        item.submenu = submenu
        return item
    }

    private static func createInfoItem(_ title: String, subtext: String?) -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSHostingView(rootView: InfoMenuRowView(title: title, subtext: subtext))
        view.frame = NSRect(x: 0, y: 0, width: menuWidth, height: subtext != nil ? 40 : 28)
        item.view = view
        item.isEnabled = true
        return item
    }

    private static func createSystemItem(for system: SystemRecord, appState: AppState) -> NSMenuItem {
        let item = NSMenuItem(
            title: system.name.isEmpty ? system.id : system.name,
            action: #selector(MenuActions.openSystemInBrowser(_:)),
            keyEquivalent: ""
        )
        item.target = MenuActions.shared
        item.representedObject = system.id

        let memoryBreakdown = appState.memoryBreakdowns[system.id]
        let hostingView = NSHostingView(
            rootView: SystemMenuRowView(system: system, memoryBreakdown: memoryBreakdown)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: menuWidth, height: 44)

        let wrapper = NSView(frame: hostingView.frame)
        wrapper.wantsLayer = true
        wrapper.layer?.backgroundColor = .clear
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        wrapper.addSubview(hostingView)
        hostingView.frame = wrapper.bounds

        item.view = wrapper

        let containers = appState.containers[system.id] ?? []
        let submenu = createSystemSubmenu(for: system, containers: containers, appState: appState)
        item.submenu = submenu

        return item
    }

    private static func createSystemSubmenu(for system: SystemRecord, containers: [ContainerRecord], appState: AppState) -> NSMenu {
        let submenu = NSMenu()

        let details = appState.systemDetails[system.id]

        let detailItem = NSMenuItem()
        let detailView = NSHostingView(rootView: SystemDetailView(
            system: system,
            details: details,
            memoryBreakdown: appState.memoryBreakdowns[system.id]
        ))
        detailView.frame = NSRect(
            x: 0, y: 0, width: 250,
            height: appState.memoryBreakdowns[system.id] == nil ? 180 : 198
        )
        detailItem.view = detailView
        submenu.addItem(detailItem)

        if !containers.isEmpty {
            submenu.addItem(NSMenuItem.separator())

            let headerItem = NSMenuItem()
            let headerView = NSHostingView(rootView:
                HStack {
                    Label("Konteynerler (\(containers.count))", systemImage: "shippingbox.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            )
            headerView.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            headerItem.view = headerView
            submenu.addItem(headerItem)

            let sortedContainers = containers.sorted { $0.name.lowercased() < $1.name.lowercased() }

            for container in sortedContainers.prefix(10) {
                let containerItem = NSMenuItem()
                let view = NSHostingView(rootView: ContainerMenuRowView(container: container))
                view.frame = NSRect(x: 0, y: 0, width: 260, height: 50)
                containerItem.view = view
                submenu.addItem(containerItem)
            }

            if containers.count > 10 {
                let moreItem = NSMenuItem(title: "+\(containers.count - 10) konteyner daha", action: nil, keyEquivalent: "")
                moreItem.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
                moreItem.image?.size = NSSize(width: 12, height: 12)

                let moreSubmenu = NSMenu()
                for container in sortedContainers.dropFirst(10) {
                    let containerItem = NSMenuItem()
                    let view = NSHostingView(rootView: ContainerMenuRowView(container: container))
                    view.frame = NSRect(x: 0, y: 0, width: 260, height: 50)
                    containerItem.view = view
                    moreSubmenu.addItem(containerItem)
                }
                moreItem.submenu = moreSubmenu
                submenu.addItem(moreItem)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let openItem = NSMenuItem(
            title: "Tarayıcıda Aç",
            action: #selector(MenuActions.openSystemInBrowser(_:)),
            keyEquivalent: ""
        )
        openItem.target = MenuActions.shared
        openItem.representedObject = system.id
        openItem.image = NSImage(systemSymbolName: "safari", accessibilityDescription: nil)
        openItem.image?.size = NSSize(width: 14, height: 14)
        submenu.addItem(openItem)

        let hostname = details?.hostname ?? system.info?.h
        if let hostname = hostname {
            let copyItem = NSMenuItem(
                title: "Makine Adını Kopyala",
                action: #selector(MenuActions.copyToClipboard(_:)),
                keyEquivalent: ""
            )
            copyItem.target = MenuActions.shared
            copyItem.representedObject = hostname
            copyItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            copyItem.image?.size = NSSize(width: 14, height: 14)
            submenu.addItem(copyItem)
        }

        return submenu
    }
}
