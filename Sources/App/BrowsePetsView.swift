import SwiftUI
import AppKit

/// A searchable gallery to download new pets into the app.
struct BrowsePetsView: View {
    @StateObject private var browser = PetBrowser()
    @AppStorage("agentpet.petBrowser.animationHintDismissed.v1") private var animationHintDismissed = false
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Browse pets").font(.headline)
                Spacer()
                Button("Done") { onClose() }
            }
            .padding(12)
            Divider()
            PetBrowserAnimationHint(dismissed: $animationHintDismissed)

            NativeSearchField(text: $browser.query, placeholder: "Search pets")
                .padding(.horizontal, 12).padding(.top, 12)

            Picker("Category", selection: $browser.category) {
                ForEach(PetBrowser.categories, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12).padding(.vertical, 8)

            if let de = browser.downloadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(de).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { browser.downloadError = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.orange.opacity(0.12))
            }

            content
        }
        .frame(width: 460, height: 580)
        .appAppearance()
        .noFocusRing()
        .onAppear { browser.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        if browser.isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Loading pets…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browser.errorText {
            VStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
                Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Retry") { browser.loadIfNeeded() }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(browser.results) { pet in
                        RemotePetRow(pet: pet, browser: browser)
                        Divider()
                    }
                }
            }
        }
    }
}

struct PetBrowserAnimationHint: View {
    @Binding var dismissed: Bool
    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 8) {
                Text("Gallery pets may not include dedicated animations for all 9 purposes and can still be used normally. After adding one, select its existing animations or import your own in Animations.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { dismissed = true } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss animation hint")
            }
            .padding(12).background(Color.accentColor.opacity(0.06))
        }
    }
}

private struct RemotePetRow: View {
    let pet: RemotePet
    @ObservedObject var browser: PetBrowser

    var body: some View {
        HStack(spacing: 12) {
            FirstFrameThumb(urlString: pet.spritesheetUrl)
                .frame(width: 44, height: 48)
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pet.name).font(.system(size: 13, weight: .medium))
                    if pet.isCommunity {
                        Text("Community")
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                    }
                }
                Text("by \(pet.author)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()

            if browser.downloading.contains(pet.slug) {
                ProgressView().controlSize(.small)
            } else if browser.installed.contains(pet.slug) {
                Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            } else {
                Button("Get") { browser.download(pet) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// Shows just the top-left frame of an 8×9 spritesheet, loaded on demand.
private struct FirstFrameThumb: View {
    let urlString: String
    // A custom loader (not AsyncImage) so we can send the Referer the Petdex
    // CDN now requires; otherwise the thumbnail request 403s.
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .frame(width: 44 * 8, height: 48 * 9)
                    .frame(width: 44, height: 48, alignment: .topLeading)
                    .clipped()
            } else if failed {
                Image(systemName: "pawprint").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: urlString) {
            guard let url = URL(string: urlString) else { failed = true; return }
            if let img = await ThumbLoader.shared.image(for: url) { image = img } else { failed = true }
        }
    }
}

/// Loads and caches Browse-pets thumbnails, capping concurrency so opening the
/// gallery doesn't burst a request per row at Petdex's rate-limited CDN.
@MainActor
final class ThumbLoader {
    static let shared = ThumbLoader()
    private let cache = NSCache<NSURL, NSImage>()
    private var active = 0

    func image(for url: URL) async -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        while active >= 3 { try? await Task.sleep(nanoseconds: 120_000_000) }
        if let cached = cache.object(forKey: key) { return cached }
        active += 1
        defer { active -= 1 }
        guard let data = try? await PetdexAssets.data(url), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}
