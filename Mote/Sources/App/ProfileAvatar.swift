import AppKit
import MoteCore
import SwiftUI
import UniformTypeIdentifiers

/// A profile's avatar: its picture, or its symbol (or initial) on its
/// colour. Round in the menus, the sidebar's foot and the Dock; in Settings
/// a squircle, the same as every other row's tile (SymbolTile).
struct ProfileAvatar: View {
    let avatar: Profiles.Avatar
    let name: String
    let picture: NSImage?
    var size: CGFloat = 28
    var squircle = false

    init(avatar: Profiles.Avatar, name: String, picture: NSImage?, size: CGFloat = 28, squircle: Bool = false) {
        self.avatar = avatar
        self.name = name
        self.picture = picture
        self.size = size
        self.squircle = squircle
    }

    init(id: String?, size: CGFloat = 28, squircle: Bool = false, profiles: Profiles = .shared) {
        self.init(
            avatar: profiles.avatar(of: id), name: profiles.name(of: id), picture: profiles.picture(of: id), size: size,
            squircle: squircle)
    }

    /// SymbolTile's corner, in proportion.
    private var shape: AnyShape {
        squircle ? AnyShape(RoundedRectangle(cornerRadius: size * 6.5 / 24, style: .continuous)) : AnyShape(Circle())
    }

    var body: some View {
        ZStack {
            Rectangle().fill((Color(hex: avatar.color) ?? .gray).gradient)
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else if let symbol = avatar.symbol {
                Image(systemName: symbol).font(.system(size: size * 11.5 / 24, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(name.prefix(1).uppercased()).font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

/// Making a profile, or changing one: its name, and an avatar from a symbol
/// on a colour or a picture placed in the circle.
struct ProfileEditor: View {
    /// The profile changed, or nil for the first; ignored when `making`.
    let id: String?
    let making: Bool
    let done: () -> Void

    @State private var name: String
    @State private var avatar: Profiles.Avatar
    @State private var picture: NSImage?
    /// A picture just chosen, still to be placed.
    @State private var placing: NSImage?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragged: CGSize = .zero
    @State private var kind: Kind

    private enum Kind: Hashable { case symbol, picture }
    private static let crop: CGFloat = 150
    private static let colors = ["#ff8558", "#f25e6b", "#f29bbb", "#a6729d", "#6cbad9", "#26456b", "#34e895", "#d7b35d", "#666789"]

    init(id: String?, making: Bool, done: @escaping () -> Void) {
        self.id = id
        self.making = making
        self.done = done
        let profiles = Profiles.shared
        let avatar = making ? Profiles.Avatar(symbol: "person.fill", color: Self.colors.randomElement() ?? "#6cbad9") : profiles.avatar(of: id)
        _name = State(initialValue: making ? "" : profiles.name(of: id))
        _avatar = State(initialValue: avatar)
        _picture = State(initialValue: making ? nil : profiles.picture(of: id))
        _kind = State(initialValue: !making && avatar.image != nil ? .picture : .symbol)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(making ? "New Profile" : "Edit Profile").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            preview
            if making || id != nil {
                TextField("Name", text: $name, prompt: Text("Work"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            Segmented(options: [(Kind.symbol, "Symbol"), (.picture, "Picture")], selection: $kind, wide: true).frame(width: 260)
            if kind == .symbol { symbols } else { pictureControls }
            colors
            HStack {
                Pill("Cancel", action: done)
                Spacer()
                Pill(making ? "Create" : "Save", filled: true, action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    /// The avatar as it will be; a picture being placed can be dragged.
    @ViewBuilder
    private var preview: some View {
        if kind == .picture, let placing {
            placed(placing)
                .clipShape(RoundedRectangle(cornerRadius: Self.crop * 6.5 / 24, style: .continuous))
                .gesture(
                    DragGesture()
                        .onChanged { dragged = $0.translation }
                        .onEnded { _ in
                            offset = CGSize(width: offset.width + dragged.width, height: offset.height + dragged.height)
                            dragged = .zero
                        })
                .help("Drag to place it")
        } else {
            ProfileAvatar(
                avatar: avatar, name: name.isEmpty ? "P" : name, picture: kind == .picture ? picture : nil, size: Self.crop,
                squircle: true)
        }
    }

    /// The picture at its zoom and place, over the colour, which shows round
    /// it while it's smaller; square, as each place clips it to its shape.
    private func placed(_ image: NSImage) -> some View {
        ZStack {
            Rectangle().fill((Color(hex: avatar.color) ?? .gray).gradient)
            Image(nsImage: image).resizable().scaledToFit()
                .scaleEffect(zoom)
                .offset(x: offset.width + dragged.width, y: offset.height + dragged.height)
        }
        .frame(width: Self.crop, height: Self.crop)
        .clipped()
    }

    private var symbols: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 8), spacing: 6) {
                ForEach(["person.fill"] + Space.icons.map(\.symbol), id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(symbol == avatar.symbol ? Palette.ink : Palette.muted)
                        .frame(width: 30, height: 30)
                        .background(symbol == avatar.symbol ? Palette.wash : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture { avatar.symbol = symbol }
                }
            }
        }
        .frame(height: 104)
    }

    private var pictureControls: some View {
        VStack(spacing: 8) {
            if placing != nil {
                HStack(spacing: 8) {
                    Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Slider(value: $zoom, in: 0.5...3)
                    Image(systemName: "photo").font(.system(size: 15)).foregroundStyle(Palette.muted)
                }
                .frame(width: 220)
            }
            Pill(placing == nil && picture == nil ? "Choose Picture…" : "Choose Another…", action: choose)
        }
    }

    private var colors: some View {
        HStack(spacing: 8) {
            ForEach(Self.colors, id: \.self) { hex in
                Circle().fill(Color(hex: hex) ?? .gray)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Palette.ink.opacity(hex == avatar.color ? 0.7 : 0), lineWidth: 2).padding(-3))
                    .onTapGesture { avatar.color = hex }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        placing = image
        zoom = 1
        offset = .zero
    }

    private func save() {
        var final = avatar
        var drawn: NSImage?
        if kind == .picture, let placing {
            // As placed, drawn at 256 pt for the Dock's sake.
            let renderer = ImageRenderer(content: placed(placing))
            renderer.scale = 256 / Self.crop
            drawn = renderer.nsImage
        } else if kind == .symbol {
            final.image = nil
        }
        let profiles = Profiles.shared
        if making {
            profiles.add(named: name.trimmingCharacters(in: .whitespaces), avatar: final, picture: drawn)
        } else {
            if let id, !name.trimmingCharacters(in: .whitespaces).isEmpty { profiles.rename(id, to: name) }
            profiles.dress(id, as: final, picture: drawn)
        }
        done()
    }
}
