//
//  ContentView.swift
//  Klipt
//
//  Created by Olaoluwakitan Oguntowo on 15/05/2026.
//

import SwiftUI
import Photos

// MARK: - Config

nonisolated(unsafe) private let backendURL = "http://localhost:8000"

// MARK: - Models

struct MediaItem: Codable {
    let url: String
    let quality: String?
    let ext: String
}

struct ResolveResponse: Codable {
    let platform: String
    let type: String
    let thumbnail: String?
    let title: String?
    let media: [MediaItem]
}

// MARK: - Download phase

enum Phase: Equatable {
    case idle
    case resolving
    case downloading
    case done(album: String)
    case failed(String)
}

// MARK: - Media service

actor MediaService {
    static let shared = MediaService()

    func resolve(url: String) async throws -> ResolveResponse {
        var request = URLRequest(url: URL(string: "\(backendURL)/resolve")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": url])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KliptError.badResponse }

        if http.statusCode != 200 {
            let detail = (try? JSONDecoder().decode([String: String].self, from: data))?["detail"]
            throw KliptError.message(detail ?? "Could not resolve this link")
        }
        return try JSONDecoder().decode(ResolveResponse.self, from: data)
    }

    func downloadToTemp(url: String) async throws -> URL {
        var request = URLRequest(url: URL(string: "\(backendURL)/download")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["url": url])
        request.timeoutInterval = 120

        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw KliptError.badResponse
        }

        let ext = (http.value(forHTTPHeaderField: "content-type") ?? "").contains("image") ? "jpg" : "mp4"
        let dest = tempURL.deletingLastPathComponent().appendingPathComponent("klipt_download.\(ext)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }
}

// MARK: - Photos saver

struct PhotosSaver {
    static func save(fileAt localURL: URL, toAlbum albumName: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw KliptError.message("Photos access is required. Please allow Klipt in Settings → Privacy → Photos.")
        }

        let album = try await fetchOrCreate(album: albumName)
        let ext = localURL.pathExtension.lowercased()
        let isVideo = ["mp4", "mov", "m4v"].contains(ext)

        try await PHPhotoLibrary.shared().performChanges {
            let request: PHAssetChangeRequest? = isVideo
                ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: localURL)
                : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: localURL)

            if let placeholder = request?.placeholderForCreatedAsset {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
    }

    private static func fetchOrCreate(album name: String) async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)
        if let album = existing.firstObject { return album }

        var placeholder: PHObjectPlaceholder?
        try await PHPhotoLibrary.shared().performChanges {
            placeholder = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name).placeholderForCreatedAssetCollection
        }
        guard let id = placeholder?.localIdentifier,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
        else { throw KliptError.message("Could not create \(name) album") }
        return album
    }
}

// MARK: - Error

enum KliptError: Error, LocalizedError {
    case badResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Server returned an unexpected response"
        case .message(let m): return m
        }
    }
}

// MARK: - Helpers

private let supportedDomains = ["twitter.com", "x.com", "tiktok.com", "instagram.com", "youtube.com", "youtu.be"]

private func isMediaURL(_ string: String) -> Bool {
    supportedDomains.contains { string.contains($0) }
}

private func albumName(for platform: String) -> String {
    switch platform {
    case "twitter":   return "Twitter"
    case "tiktok":    return "TikTok"
    case "instagram": return "Instagram"
    case "youtube":   return "YouTube"
    default:          return "Klipt"
    }
}

private func platformIcon(for platform: String) -> String {
    switch platform {
    case "twitter":   return "bird"
    case "tiktok":    return "music.note"
    case "instagram": return "camera"
    case "youtube":   return "play.rectangle"
    default:          return "link"
    }
}

private func detectedPlatform(from url: String) -> String? {
    if url.contains("twitter.com") || url.contains("x.com") { return "twitter" }
    if url.contains("tiktok.com") { return "tiktok" }
    if url.contains("instagram.com") { return "instagram" }
    if url.contains("youtube.com") || url.contains("youtu.be") { return "youtube" }
    return nil
}

// MARK: - Main view

struct ContentView: View {
    @State private var urlText = ""
    @State private var phase: Phase = .idle

    private var detectedPlatformName: String? { detectedPlatform(from: urlText) }
    private var isWorking: Bool { phase == .resolving || phase == .downloading }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 72)

                header
                    .padding(.bottom, 48)

                inputCard
                    .padding(.horizontal, 24)

                statusArea
                    .padding(.top, 28)
                    .padding(.horizontal, 24)

                Spacer()
            }
        }
        .onAppear(perform: checkClipboard)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 8) {
            Text("Klipt")
                .font(.system(size: 44, weight: .black, design: .rounded))
            Text("Paste a link. Save the media.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Input card

    private var inputCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                if let platform = detectedPlatformName {
                    Image(systemName: platformIcon(for: platform))
                        .foregroundStyle(.tint)
                        .frame(width: 20)
                }

                TextField("Twitter, TikTok, Instagram or YouTube link", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { Task { await download() } }

                if !urlText.isEmpty {
                    Button { urlText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            HStack(spacing: 10) {
                Button(action: paste) {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.bordered)
                .tint(.secondary)

                Button(action: { Task { await download() } }) {
                    Group {
                        if isWorking {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                        } else {
                            Label("Save", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
    }

    // MARK: Status area

    @ViewBuilder
    private var statusArea: some View {
        switch phase {
        case .idle:
            EmptyView()

        case .resolving:
            statusRow(icon: "link", text: "Resolving link…", color: .secondary)

        case .downloading:
            statusRow(icon: "arrow.down.circle", text: "Downloading…", color: .secondary)

        case .done(let album):
            statusRow(icon: "checkmark.circle.fill", text: "Saved to \(album) album", color: .green)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if case .done = phase { phase = .idle }
                    }
                }

        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .padding(.top, 1)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func statusRow(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(color == .secondary ? .secondary : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    private func checkClipboard() {
        guard let string = UIPasteboard.general.string, isMediaURL(string) else { return }
        urlText = string
    }

    private func paste() {
        guard let string = UIPasteboard.general.string else { return }
        urlText = string
    }

    private func download() async {
        let url = urlText.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }

        phase = .resolving

        do {
            let resolved = try await MediaService.shared.resolve(url: url)
            let album = albumName(for: resolved.platform)

            phase = .downloading
            let localFile = try await MediaService.shared.downloadToTemp(url: url)
            defer { try? FileManager.default.removeItem(at: localFile) }

            try await PhotosSaver.save(fileAt: localFile, toAlbum: album)
            phase = .done(album: album)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

#Preview {
    ContentView()
}
