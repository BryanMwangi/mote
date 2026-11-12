import Combine
import MoteCore
import SwiftUI
import WebKit

// Responsive Design Mode (⌃⌘R): a tab's page
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
        web.customUserAgent = device.flatMap { $0.userAgent.isEmpty ? nil : $0.userAgent } ?? userAgent ?? ""
    }
}

/// Above the page in Responsive Design Mode, as Firefox's: the device, its
/// size, turning it, its pixel density, user agent and touch in the middle;
/// a screenshot and leaving at the end.
struct DeviceBar: View {
    @ObservedObject var tab: Tab
    /// The size as a handle drags it, shown as it changes.
    @ObservedObject var drag: DeviceDrag
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
            side(drag.size?.width ?? device.width) { tab.device = device.sized(width: $0, height: device.height) }
            Text("×").foregroundStyle(Palette.muted)
            side(drag.size?.height ?? device.height) { tab.device = device.sized(width: device.width, height: $0) }
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

/// Which way a device's handle drags.
private enum Side { case leading, trailing, bottom }

/// Around the device's page: its outline, and handles on its sides and
/// foot, as Safari's, each dragging the size its way.
struct DeviceFrame: View {
    @ObservedObject var tab: Tab
    @ObservedObject var drag: DeviceDrag
    let device: Device

    /// The size and scale when a drag began: the scale held for the drag,
    /// so the handle keeps up with the pointer as the fit changes.
    @State private var start: (size: CGSize, scale: CGFloat)?

    var body: some View {
        GeometryReader { area in
            let placed = Devices.place(
                drag.size ?? device.size,
                in: CGRect(origin: .zero, size: area.size).insetBy(dx: StageView.margin, dy: StageView.margin),
                fits: tab.deviceFits, held: drag.held)
            let frame = placed.frame
            Rectangle().strokeBorder(Palette.ink.opacity(0.18))
                .frame(width: frame.width + 2, height: frame.height + 2)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
            // Last: placed views fill the area, and a handle's drag mustn't
            // cover the page, or it takes the page's scrolls and clicks.
            handle(.leading, placed.scale).position(x: frame.minX - 9, y: frame.midY)
            handle(.trailing, placed.scale).position(x: frame.maxX + 9, y: frame.midY)
            handle(.bottom, placed.scale).position(x: frame.midX, y: min(frame.maxY + 9, area.size.height - 7))
        }
        .coordinateSpace(name: Self.area)
    }

    /// The drag is measured here, not on the handle: the handle moves with
    /// each step, and measured from it the pointer's travel is lost and the
    /// size swings back and forth.
    private static let area = "deviceArea"

    private func handle(_ side: Side, _ scale: CGFloat) -> some View {
        let across = side == .bottom
        return Capsule()
            .fill(Palette.muted.opacity(0.6))
            .frame(width: across ? 44 : 5, height: across ? 5 : 44)
            .frame(width: across ? 72 : 16, height: across ? 16 : 72)
            .contentShape(Rectangle())
            .gesture(drag(side, scale))
            .modifier(ResizePointer(side: side))
            .help(across ? "Drag to change the height" : "Drag to change the width")
    }

    /// The page is centred across, so its width changes twice what a side
    /// handle moves; its height, as the foot's moves.
    private func drag(_ side: Side, _ scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.area))
            .onChanged { motion in
                let from = start ?? (device.size, scale)
                if start == nil { start = from }
                var size = from.size
                switch side {
                case .leading: size.width -= 2 * motion.translation.width / from.scale
                case .trailing: size.width += 2 * motion.translation.width / from.scale
                case .bottom: size.height += motion.translation.height / from.scale
                }
                tab.dragDevice(
                    to: CGSize(width: max(Devices.smallest, size.width), height: max(Devices.smallest, size.height)), holding: from.scale)
            }
            .onEnded { _ in
                start = nil
                tab.endDeviceDrag()
            }
    }
}

/// A device's size being dragged: the scale held, the size its outline
/// shows, and the page's next resize.
@MainActor
final class DeviceDrag: ObservableObject {
    @Published var size: CGSize?
    var held: CGFloat?
}

extension Tab {
    /// The device's size dragged: the page and its outline follow at once, at
    /// the scale they had, so the page grows under the pointer instead of being
    /// fitted, and zoomed, anew. Only the stage and the outline redraw; the
    /// tab's device changes when the drag ends.
    func dragDevice(to size: CGSize, holding scale: CGFloat) {
        if deviceDrag.held == nil {
            deviceDrag.held = scale
            built?.resizingByHand = true
        }
        // Whole points: a page laid out at fractions of one shifts as it grows.
        let rounded = CGSize(width: size.width.rounded(), height: size.height.rounded())
        if deviceDrag.size != rounded { deviceDrag.size = rounded }
    }

    /// The drag let go: the page takes its last size, and is fitted again.
    func endDeviceDrag() {
        resizeToDragged()
        built?.resizingByHand = false
        deviceDrag.held = nil
        deviceDrag.size = nil
        // Fitted again at the size it ended at.
        objectWillChange.send()
    }

    private func resizeToDragged() {
        guard let size = deviceDrag.size, let device else { return }
        self.device = device.sized(width: size.width, height: size.height)
    }
}

/// A resize pointer over a handle. macOS 15 keeps it through the drag; before,
/// it's set on hover.
private struct ResizePointer: ViewModifier {
    let side: Side

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(.frameResize(position: side == .leading ? .leading : side == .trailing ? .trailing : .bottom))
        } else {
            content.onHover { inside in
                (inside ? (side == .bottom ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight) : NSCursor.arrow).set()
            }
        }
    }
}
