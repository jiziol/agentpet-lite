import SwiftUI
import UniformTypeIdentifiers

struct CreatePetView: View {
    var onCreate: (String) -> Void
    var onCancel: () -> Void

    @State private var displayName = ""
    @State private var description = ""
    @State private var spritesheetURL: URL?
    @State private var errorText: String?

    private var canCreate: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && spritesheetURL != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create pet").font(.headline)
                Spacer()
                Button("Cancel") { onCancel() }
            }
            .padding(12)
            Divider()

            Form {
                Section("Pet info") {
                    TextField("Name", text: $displayName)
                    TextField("Description", text: $description)
                }

                Section {
                    HStack {
                        Text(spritesheetURL?.lastPathComponent ?? "No image selected")
                            .foregroundStyle(spritesheetURL == nil ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        Button("Choose image…") { chooseSpritesheet() }
                    }
                } header: {
                    Text("Spritesheet")
                } footer: {
                    Text("Use the same 8×9 transparent spritesheet format as downloaded pets.")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.systemAccent)
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 480, height: 430)
        .appAppearance()
        .noFocusRing()
    }

    private func chooseSpritesheet() {
        let panel = NSOpenPanel()
        panel.title = "Choose Spritesheet"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]

        if panel.runModal() == .OK {
            spritesheetURL = panel.url
            errorText = nil
        }
    }

    private func create() {
        guard let spritesheetURL else { return }
        guard let id = PetInstaller.createLocalPack(
            displayName: displayName,
            description: description,
            spritesheetURL: spritesheetURL
        ) else {
            errorText = "Could not create this pet. Check that the image is a valid spritesheet."
            return
        }
        onCreate(id)
    }
}
