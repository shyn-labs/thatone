import SwiftUI
import ThatOneCore

struct SettingsView: View {
    let model: AppModel
    @State private var presetID: String
    @State private var folders: [String]
    @State private var exclusions: [String]
    @State private var login: LoginItem.State = LoginItem.state()
    @State private var loginError: String?
    @State private var photos: PhotosState
    @State private var photosCount: Int
    @State private var photosEnabled: Bool
    @State private var kinds: Set<String>
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(model: AppModel) {
        self.model = model
        _presetID = State(initialValue: model.currentPreset.id)
        _folders = State(initialValue: model.host.snapshot.folders)
        _exclusions = State(initialValue: model.exclusions)
        _photos = State(initialValue: model.host.snapshot.photos)
        _photosCount = State(initialValue: model.host.snapshot.photosCount)
        _photosEnabled = State(initialValue: model.host.snapshot.photosEnabled)
        _kinds = State(initialValue: model.host.snapshot.enabledKinds)
    }

    var body: some View {
        Form {
            Picker("Search shortcut", selection: $presetID) {
                ForEach(HotKeyPreset.all) { Text($0.label).tag($0.id) }
            }
            .onChange(of: presetID) { _, id in model.setHotKey(HotKeyPreset.preset(id: id)) }
            if let problem = model.host.snapshot.hotKeyProblem { Text("Shortcut unavailable: \(problem)").foregroundStyle(.orange) }

            Toggle("Open at login", isOn: Binding(get: { login == .enabled }, set: { on in
                do { try LoginItem.setEnabled(on); loginError = nil } catch { loginError = "\(error)" }
                login = LoginItem.state()
            }))
            if login == .requiresApproval { Text("Approve ThatOne in System Settings > General > Login Items.").font(.caption) }
            if case .unavailable(let why) = login { Text(why).font(.caption).foregroundStyle(.secondary) }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }

            Section("What to index") {
                ForEach(KindSwitch.all) { entry in
                    Toggle(entry.title, isOn: Binding(get: { kinds.contains(entry.kind) }, set: { on in
                        kinds = KindSwitch.toggled(kinds, entry.kind, on: on)
                        model.host.setKinds(kinds)
                    }))
                    if let note = entry.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Apple Photos") {
                Toggle("Include my Apple Photos", isOn: Binding(get: { photosEnabled || photos == .needsPermission },
                                                                 set: { model.host.setPhotos($0) }))
                switch photos {
                case .off: Text("Off. Turning it on asks macOS for permission to read your photos.").font(.caption).foregroundStyle(.secondary)
                case .needsPermission: Text("Waiting for your answer to the macOS prompt.").font(.caption).foregroundStyle(.secondary)
                case .denied: HStack { Text(photosEnabled ? "Access was revoked. Turn this off to forget the photos already indexed." : "Access was denied.").font(.caption).foregroundStyle(.orange); Button("Open Settings") { PhotosAccess.openSettings() } }
                case .restricted: Text("Photos access is restricted on this Mac.").font(.caption).foregroundStyle(.orange)
                case .on(let limited): Text("\(photosCount) photos indexed" + (limited ? " (you gave access to selected photos only)" : "") + ". Hidden and Recently Deleted photos are never read.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Folders") {
                if folders.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Text(folder).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Remove") { model.removeFolder(folder); folders.removeAll { $0 == folder } }
                    }
                }
            }
            Section("Never indexed") {
                if exclusions.isEmpty { Text("Nothing excluded").foregroundStyle(.secondary) }
                ForEach(exclusions, id: \.self) { path in
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Allow again") { model.removeExclusion(path); exclusions.removeAll { $0 == path } }
                    }
                }
            }
            Section("About") {
                Text("ThatOne \(AppVersion.string)").font(.caption)
                Text("Index and data stay in \(model.engine.paths.home.path)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            photos = model.host.snapshot.photos
            photosCount = model.host.snapshot.photosCount
            photosEnabled = model.host.snapshot.photosEnabled
            kinds = model.host.snapshot.enabledKinds
        }
        .frame(width: 520, height: 460)
    }
}
