import Combine
import MoteCore
import SwiftUI
import WebKit

// Responsive Design Mode (⌃⌘R), after Firefox's (and so Zen's): a tab's page
// shown at a device's size. The stage lays the page out at that size
// (WebStage), the tab gives it the device's user agent, pixel density and
// touch, and a bar above the page changes them. The devices are Firefox's
// list, plus the user's own. Touch events and the `viewport` meta tag aren't
// emulated: macOS WebKit has neither; on a touch device dragging scrolls.

/// The devices: Firefox's (Mote/Resources/devices.json) and the user's own,
/// and which of them the bar's menu shows. Both are kept in the settings.
@MainActor
final class DeviceList: ObservableObject {
    static let shared = DeviceList()

    private static let firefox: [Device] = {
        guard let url = Bundle.main.url(forResource: "devices", withExtension: "json"), let data = try? Data(contentsOf: url) else {
            return []
        }
        return (try? Devices.decode(data)) ?? []
    }()

    @Published private(set) var custom: [Device]
    /// By name. Firefox's featured devices until the list is edited.
    @Published private(set) var shown: Set<String>

    private init() {
        let store = Storage.settings
        custom = store.data(forKey: "devices.custom").flatMap { try? Devices.decode($0) } ?? []
        shown = Set(store.stringArray(forKey: "devices.shown") ?? Self.firefox.filter(\.featured).map(\.name))
    }

    var all: [Device] { Self.firefox + custom }
    /// The menu's, by name, as Firefox's.
    var menu: [Device] { all.filter { shown.contains($0.name) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    func device(named name: String) -> Device? { all.first { $0.name == name } }

    func show(_ name: String, _ on: Bool) {
        if on { shown.insert(name) } else { shown.remove(name) }
        Storage.settings.set(Array(shown), forKey: "devices.shown")
    }

    func add(_ device: Device) {
        custom.removeAll { $0.name == device.name }
        custom.append(device)
        show(device.name, true)
        save()
    }

    func remove(_ device: Device) {
        custom.removeAll { $0.name == device.name }
        show(device.name, false)
        save()
    }

    private func save() {
        Storage.settings.set(try? JSONEncoder().encode(custom), forKey: "devices.custom")
    }
}

/// The device last used, for the next tab put in the mode.
@MainActor private var lastDevice: Device?

extension Browser {
    func toggleResponsive() {
        guard let tab = active, !tab.isBlank else { return }
        if let device = tab.device {
            lastDevice = device
            tab.device = nil
        } else {
            let list = DeviceList.shared
            tab.device = lastDevice ?? list.device(named: "iPhone 14 / 15 / 16") ?? list.menu.first ?? list.all.first
        }
    }
}

extension Tab {
    /// The page as the device sees it, or as itself again: its pixel density
    /// (`devicePixelRatio`, through WebKit's own override), dragging to scroll
    /// on a touch device, and its user agent. Nothing reloads, so sizes can be
    /// tried one after another; the user agent goes with the next load, as in
    /// Firefox.
    func emulate() {
        guard let web = built else { return }
        web.unpublished("_setOverrideDeviceScaleFactor:", device?.scale ?? 0)
        web.touchScrolls = device?.touch == true
        web.customUserAgent = device?.userAgent ?? ""
    }

    /// A picture of what the page shows (at the device's width in
    /// Responsive Design Mode), into the downloads folder.
    func screenshot() {
        guard let web = built, let browser = owner as? Browser else { return }
        let shot = WKSnapshotConfiguration()
        var name = "\(label) – screenshot.png"
        if let device {
            shot.snapshotWidth = NSNumber(value: Double(device.width))
            name = "\(label) – \(device.name) \(Int(device.width))×\(Int(device.height)).png"
        }
        let file = browser.downloadsFolder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        web.takeSnapshot(with: shot) { image, _ in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation,
                    let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                    (try? png.write(to: file)) != nil
                else { return browser.announce("The screenshot couldn't be saved") }
                browser.announce("Screenshot saved to \(browser.downloadsFolder.lastPathComponent)")
            }
        }
    }
}

/// Above the page in Responsive Design Mode, as Firefox's: the device, its
/// size, turning it, its pixel density, user agent and touch in the middle;
/// a screenshot and leaving at the end.
struct DeviceBar: View {
    @ObservedObject var tab: Tab
    let device: Device
    @ObservedObject private var list = DeviceList.shared
    @State private var editing = false

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Menu {
                ForEach(list.menu, id: \.name) { listed in
                    Toggle(listed.name, isOn: Binding(get: { listed.name == device.name }, set: { _ in tab.device = listed }))
                }
                Divider()
                Button("Edit List…") { editing = true }
            } label: {
                Label(device.name, systemImage: icon(device))
            }
            .fixedSize()
            side(device.width) { tab.device = device.sized(width: $0, height: device.height) }
            Text("×").foregroundStyle(Palette.muted)
            side(device.height) { tab.device = device.sized(width: device.width, height: $0) }
            Door(icon: "rotate.right", help: "Rotate") { tab.device = device.rotated }
            divider
            Menu("DPR: \(device.scale.formatted())") {
                ForEach([1, 2, 3] as [CGFloat], id: \.self) { scale in
                    Button("\(Int(scale))") { tab.device?.scale = scale }
                }
            }
            .fixedSize()
            divider
            Menu(device.userAgent.isEmpty ? "UA: Mote" : "UA: \(device.name)") {
                Button("This device's") { tab.device?.userAgent = list.device(named: device.name)?.userAgent ?? "" }
                    .disabled(list.device(named: device.name)?.userAgent.isEmpty ?? true)
                Button("Mote's") { tab.device?.userAgent = "" }
            }
            .fixedSize()
            .help(device.userAgent.isEmpty ? "Mote's own user agent" : device.userAgent)
            Door(icon: "hand.point.up.left", on: device.touch, help: device.touch ? "Touch: dragging scrolls" : "Mouse") {
                tab.device?.touch.toggle()
            }
            divider
            Door(
                icon: tab.deviceFits ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: tab.deviceFits ? "Shown fitted to the window" : "Shown at its own size"
            ) {
                tab.deviceFits.toggle()
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 2) {
                Door(icon: "camera", help: "Screenshot") { tab.screenshot() }
                Door(icon: "xmark", help: "Leave Responsive Design Mode   ⌃⌘R") { tab.device = nil }
            }
        }
        .font(TextStyle.secondary.font)
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(Palette.frame)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairline).frame(height: 1) }
        .sheet(isPresented: $editing) { DeviceSettings(list: list) { editing = false } }
    }

    private var divider: some View { Rectangle().fill(Palette.hairline).frame(width: 1, height: 16) }

    /// A width or height to type, applied on Return.
    private func side(_ value: CGFloat, set: @escaping (CGFloat) -> Void) -> some View {
        TextField("", value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }), format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: 52)
    }
}

private func icon(_ device: Device) -> String {
    switch device.type {
    case "phones": "iphone"
    case "tablets": "ipad"
    case "televisions": "tv"
    default: "laptopcomputer"
    }
}

/// "Edit List…": every device, by kind, ticked to be in the menu; the
/// user's own can be added and removed. As Firefox's Device Settings.
private struct DeviceSettings: View {
    @ObservedObject var list: DeviceList
    let done: () -> Void
    @State private var adding = false

    private static let kinds = [
        ("phones", "Phones"), ("tablets", "Tablets"), ("laptops", "Laptops"), ("televisions", "TVs"), (Devices.customType, "Your devices"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Device Settings").font(TextStyle.title.font)
                Spacer()
                Button("Add Custom Device…") { adding = true }
            }
            .padding(20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Self.kinds, id: \.0) { kind, title in
                        let devices = list.all.filter { $0.type == kind }
                        if !devices.isEmpty {
                            Text(title).font(TextStyle.body.font.weight(.semibold))
                            LazyVGrid(
                                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                                spacing: 6
                            ) {
                                ForEach(devices, id: \.name) { row($0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 560)
        .sheet(isPresented: $adding) { NewDevice(list: list) { adding = false } }
    }

    private func row(_ device: Device) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: Binding(get: { list.shown.contains(device.name) }, set: { list.show(device.name, $0) })) {
                Label(device.name, systemImage: icon(device))
            }
            .toggleStyle(.checkbox)
            Text("\(Int(device.width))×\(Int(device.height))").foregroundStyle(Palette.muted).monospacedDigit()
            if device.type == Devices.customType {
                Button {
                    list.remove(device)
                } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).help("Remove")
            }
        }
        .font(TextStyle.secondary.font)
    }
}

/// "Add Custom Device…": its name, size, pixel ratio, user agent and touch.
private struct NewDevice: View {
    let list: DeviceList
    let done: () -> Void
    @State private var device = Device(name: "", width: 400, height: 800, scale: 2, touch: true)

    var body: some View {
        Form {
            TextField("Name", text: $device.name)
            TextField("Width", value: number(\.width), format: .number.grouping(.never))
            TextField("Height", value: number(\.height), format: .number.grouping(.never))
            TextField("Pixel ratio", value: number(\.scale), format: .number)
            TextField("User agent", text: $device.userAgent, prompt: Text("Mote's own"))
            Toggle("Touch", isOn: $device.touch)
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Add") {
                    list.add(device.sized(width: device.width, height: device.height))
                    done()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(device.name.trimmingCharacters(in: .whitespaces).isEmpty || list.device(named: device.name) != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func number(_ side: WritableKeyPath<Device, CGFloat>) -> Binding<Double> {
        Binding(get: { Double(device[keyPath: side]) }, set: { device[keyPath: side] = CGFloat($0) })
    }
}

/// Around the device, where the stage puts it (WebStage): its outline, and a
/// grip on its corner to drag its size.
struct DeviceFrame: View {
    @ObservedObject var tab: Tab
    let device: Device

    /// The size when a drag began.
    @State private var start: CGSize?

    var body: some View {
        GeometryReader { area in
            let placed = Devices.place(
                device.size, in: CGRect(origin: .zero, size: area.size).insetBy(dx: StageView.margin, dy: StageView.margin),
                fits: tab.deviceFits)
            let frame = placed.frame
            Rectangle().strokeBorder(Palette.ink.opacity(0.18))
                .frame(width: frame.width + 2, height: frame.height + 2)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(90))
                .foregroundStyle(Palette.muted)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .gesture(drag(placed.scale))
                .onHover { inside in (inside ? NSCursor.crosshair : NSCursor.arrow).set() }
                .help("Drag to resize")
                // Last: placed views fill the area, and the grip's drag mustn't
                // cover the page, or it takes the page's scrolls and clicks.
                .position(x: frame.maxX + 10, y: min(frame.maxY + 10, area.size.height - 9))
        }
    }

    /// The page is centred across, so its width grows twice what the corner
    /// moves; down, as it moves.
    private func drag(_ scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { motion in
                let from = start ?? device.size
                if start == nil { start = from }
                tab.device = device.sized(
                    width: from.width + 2 * motion.translation.width / scale, height: from.height + motion.translation.height / scale)
            }
            .onEnded { _ in start = nil }
    }
}
