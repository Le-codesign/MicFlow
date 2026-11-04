import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Data

struct FeatureRequest: Codable, Identifiable, Equatable {
    var id: String
    /// Who posted it; older lists don't say.
    var author_id: String?
    var title: String
    var body: String
    var images: [String]
    var author_name: String?
    var author_avatar: String?
    var created_at: Date
    var upvotes: Int
    var downvotes: Int
    var comments: Int

    var score: Int { upvotes - downvotes }
}

struct RequestComment: Codable, Identifiable, Equatable {
    var id: String
    var author_id: String?
    var body: String
    var author_name: String?
    var author_avatar: String?
    var created_at: Date
}

@MainActor
final class FeatureRequestStore: ObservableObject {
    @Published private(set) var requests: [FeatureRequest] = []
    /// Your vote on each request: 1 up, -1 down.
    @Published private(set) var myVotes: [String: Int] = [:]
    @Published private(set) var comments: [String: [RequestComment]] = [:]
    @Published private(set) var isLoading = false
    @Published var error: String?

    let account: Account

    init(account: Account) { self.account = account }

    func refresh() {
        guard BackendConfig.isConfigured, !isLoading else { return }
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let data = try await Backend.request("GET", "/rest/v1/feature_request_list", query: [
                    URLQueryItem(name: "select", value: "*"),
                    URLQueryItem(name: "order", value: "score.desc,created_at.desc"),
                    URLQueryItem(name: "limit", value: "200"),
                ], token: try? await account.token())
                var list = try Backend.decoder().decode([FeatureRequest].self, from: data)
                // Who posted each one, straight from the requests (in case the list doesn't say).
                if list.contains(where: { $0.author_id == nil }),
                   let authors = try? await Backend.request("GET", "/rest/v1/feature_requests", query: [
                       URLQueryItem(name: "select", value: "id,author_id"),
                   ], token: try? await account.token()),
                   let rows = try? JSONSerialization.jsonObject(with: authors) as? [[String: Any]] {
                    let byID = Dictionary(rows.compactMap { row in
                        (row["id"] as? String).map { ($0, row["author_id"] as? String) }
                    }, uniquingKeysWith: { a, _ in a })
                    for index in list.indices where list[index].author_id == nil {
                        list[index].author_id = byID[list[index].id] ?? nil
                    }
                }
                requests = list
                if let token = try? await account.token(), let id = account.user?.id {
                    let votes = try await Backend.request("GET", "/rest/v1/votes", query: [
                        URLQueryItem(name: "select", value: "request_id,value"),
                        URLQueryItem(name: "voter_id", value: "eq.\(id)"),
                    ], token: token)
                    let rows = (try JSONSerialization.jsonObject(with: votes) as? [[String: Any]]) ?? []
                    myVotes = Dictionary(rows.compactMap { row in
                        (row["request_id"] as? String).map { ($0, row["value"] as? Int ?? 0) }
                    }, uniquingKeysWith: { a, _ in a })
                }
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Up (1) or down (-1). Pressing your current vote again takes it back. No sign-in needed:
    /// each Mac (or account) has one vote per request.
    func vote(_ request: FeatureRequest, _ value: Int) {
        let previous = myVotes[request.id]
        let new = previous == value ? nil : value
        apply(request.id, from: previous, to: new)
        Task {
            do {
                guard let token = try await account.token(orDevice: true), let voter = account.user?.id else { return }
                if let new {
                    _ = try await Backend.request("POST", "/rest/v1/votes", json: [["request_id": request.id, "voter_id": voter, "value": new]],
                                                  token: token, prefer: "resolution=merge-duplicates,return=minimal")
                } else {
                    _ = try await Backend.request("DELETE", "/rest/v1/votes", query: [
                        URLQueryItem(name: "request_id", value: "eq.\(request.id)"),
                        URLQueryItem(name: "voter_id", value: "eq.\(voter)"),
                    ], token: token)
                }
            } catch {
                apply(request.id, from: new, to: previous)
                self.error = "Your vote wasn't saved: \(error.localizedDescription)"
            }
        }
    }

    /// Shows a vote at once, before the server answers.
    private func apply(_ id: String, from old: Int?, to new: Int?) {
        myVotes[id] = new
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        if old == 1 { requests[index].upvotes -= 1 }
        if old == -1 { requests[index].downvotes -= 1 }
        if new == 1 { requests[index].upvotes += 1 }
        if new == -1 { requests[index].downvotes += 1 }
    }

    func loadComments(_ request: FeatureRequest) {
        Task {
            do {
                let data = try await Backend.request("GET", "/rest/v1/comments", query: [
                    URLQueryItem(name: "select", value: "id,author_id,body,author_name,author_avatar,created_at"),
                    URLQueryItem(name: "request_id", value: "eq.\(request.id)"),
                    URLQueryItem(name: "order", value: "created_at.asc"),
                ], token: try? await account.token())
                comments[request.id] = try Backend.decoder().decode([RequestComment].self, from: data)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func addComment(_ text: String, to request: FeatureRequest) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, account.isSignedIn else { return false }
        do {
            guard let token = try await account.token(), let user = account.user else { return false }
            _ = try await Backend.request("POST", "/rest/v1/comments", json: [[
                "request_id": request.id, "body": text, "author_id": user.id,
                "author_name": user.name ?? "MicFlow user", "author_avatar": user.avatar ?? "",
            ]], token: token, prefer: "return=minimal")
            loadComments(request)
            if let index = requests.firstIndex(where: { $0.id == request.id }) { requests[index].comments += 1 }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Whether you may delete this: it's yours, or you're the admin.
    func canDelete(authorID: String?) -> Bool {
        guard account.isSignedIn else { return false }
        return account.isAdmin || (authorID != nil && authorID == account.user?.id)
    }

    /// Deletes a request with its votes, comments and pictures. The database allows it only for the
    /// author or an admin, whatever the app shows.
    func delete(_ request: FeatureRequest) async -> Bool {
        do {
            guard let token = try await account.token() else { return false }
            let data = try await Backend.request("DELETE", "/rest/v1/feature_requests", query: [
                URLQueryItem(name: "id", value: "eq.\(request.id)"),
            ], token: token, prefer: "return=representation")
            // Nothing deleted means the database said no.
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any], !rows.isEmpty else {
                error = "Only the person who posted this, or the admin, can delete it."
                return false
            }
            if !request.images.isEmpty {
                let names = request.images.map { $0.replacingOccurrences(of: "feature-images/", with: "") }
                _ = try? await Backend.request("DELETE", "/storage/v1/object/feature-images", json: ["prefixes": names], token: token)
            }
            requests.removeAll { $0.id == request.id }
            comments[request.id] = nil
            myVotes[request.id] = nil
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func deleteComment(_ comment: RequestComment, on request: FeatureRequest) async {
        do {
            guard let token = try await account.token() else { return }
            let data = try await Backend.request("DELETE", "/rest/v1/comments", query: [
                URLQueryItem(name: "id", value: "eq.\(comment.id)"),
            ], token: token, prefer: "return=representation")
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any], !rows.isEmpty else {
                error = "Only the person who wrote this comment, or the admin, can delete it."
                return
            }
            comments[request.id]?.removeAll { $0.id == comment.id }
            if let index = requests.firstIndex(where: { $0.id == request.id }) { requests[index].comments -= 1 }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Uploads the pictures, then posts the request.
    func post(title: String, body: String, images: [Data]) async -> Bool {
        guard account.isSignedIn else { return false }
        do {
            guard let token = try await account.token(), let user = account.user else { return false }
            var paths: [String] = []
            for image in images {
                let path = "\(user.id)/\(UUID().uuidString.lowercased()).jpg"
                _ = try await Backend.request("POST", "/storage/v1/object/feature-images/\(path)", data: image,
                                              contentType: "image/jpeg", token: token)
                paths.append("feature-images/\(path)")
            }
            _ = try await Backend.request("POST", "/rest/v1/feature_requests", json: [[
                "title": title, "body": body, "images": paths, "author_id": user.id,
                "author_name": user.name ?? "MicFlow user", "author_avatar": user.avatar ?? "",
            ]], token: token, prefer: "return=minimal")
            refresh()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

// MARK: - Views

/// Settings › Feature Requests: the five most-wanted, then the rest, each with up and down votes.
struct FeatureRequestsPage: View {
    @ObservedObject var store: FeatureRequestStore
    @ObservedObject var account: Account
    let theme: HomeTheme
    @State private var showAll = false
    @State private var open: FeatureRequest?
    @State private var composing = false
    @State private var toDelete: FeatureRequest?
    /// Signing in to post: the form opens once sign-in finishes.
    @State private var wantsToCompose = false

    var body: some View {
        if !BackendConfig.isConfigured {
            PageBody {
                HeroCard(kicker: "Feature Requests", title: "Coming soon",
                         detail: "Requesting and voting on features will open here soon.", systemImage: "lightbulb.fill") { EmptyView() }
            }
        } else if let request = open.flatMap({ current in store.requests.first { $0.id == current.id } ?? current }) {
            RequestDetail(request: request, store: store, account: account, theme: theme) { open = nil }
        } else {
            PageBody {
                HeroCard(kicker: "Feature Requests", title: "What should MicFlow do next?",
                         detail: "Vote for the ideas you want most; no sign-in needed. Sign in with Google to post an idea or comment.",
                         chip: "\(store.requests.count) ideas", systemImage: "lightbulb.fill") {
                    PillButton(title: "Request a feature", systemImage: "plus", style: .ink) {
                        if account.isSignedIn { composing = true } else { wantsToCompose = true; account.signIn(setUpKey: false) }
                    }
                    PillButton(title: "Refresh", systemImage: "arrow.clockwise", style: .orange, action: store.refresh)
                }
                if let error = store.error { Note(text: error, isError: true) }
                WhitePanel {
                    HStack(alignment: .firstTextBaseline) {
                        Text(showAll ? "All requests" : "Most wanted").font(.display(24))
                        Text("by votes").font(.system(size: 12)).foregroundStyle(Palette.greyOnLight)
                        Spacer()
                        if store.isLoading { ProgressView().controlSize(.small) }
                    }
                    if store.requests.isEmpty, !store.isLoading {
                        Text("No requests yet. Be the first to ask for something!").font(.system(size: 13))
                            .foregroundStyle(Palette.greyOnLight)
                    }
                    ForEach(showAll ? store.requests : Array(store.requests.prefix(5))) { request in
                        RequestRow(request: request, myVote: store.myVotes[request.id],
                                   canDelete: store.canDelete(authorID: request.author_id),
                                   delete: { toDelete = request }) { store.vote(request, $0) } open: {
                            open = request
                            store.loadComments(request)
                        }
                    }
                    if store.requests.count > 5 {
                        PillButton(title: showAll ? "Show the top 5" : "See \(store.requests.count - 5) more requests",
                                   systemImage: showAll ? "chevron.up" : "chevron.down", style: .ink) { showAll.toggle() }
                    }
                }
            }
            .sheet(isPresented: $composing) { ComposeRequest(store: store) }
            .onChange(of: account.isSignedIn) { signedIn in
                if signedIn, wantsToCompose { wantsToCompose = false; composing = true }
            }
            .alert("Delete this request?", isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let request = toDelete { Task { _ = await store.delete(request) } }
                    toDelete = nil
                }
                Button("Cancel", role: .cancel) { toDelete = nil }
            } message: {
                Text("\"\(toDelete?.title ?? "")\" and its votes, comments and pictures will be deleted for everyone. This can't be undone.")
            }
            .onAppear { if store.requests.isEmpty { store.refresh() } }
        }
    }
}

private struct RequestRow: View {
    let request: FeatureRequest
    let myVote: Int?
    var canDelete = false
    var delete: () -> Void = {}
    let vote: (Int) -> Void
    let open: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading)
                    Text(request.body).font(.system(size: 12)).foregroundStyle(Palette.greyOnLight).lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 10) {
                        Label("\(request.comments)", systemImage: "bubble.left")
                        if !request.images.isEmpty { Label("\(request.images.count)", systemImage: "photo") }
                        Text(request.author_name ?? "")
                    }
                    .font(.system(size: 11)).foregroundStyle(Palette.greyOnLight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if canDelete {
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.orange)
                        .frame(width: 40, height: 50)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("Delete this request")
            }
            VoteButtons(request: request, myVote: myVote, vote: vote)
        }
        .padding(14)
        .background(Color(hex: 0xF2F2F0), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Up and down, each with how many people chose it. Yours is filled in.
private struct VoteButtons: View {
    let request: FeatureRequest
    let myVote: Int?
    let vote: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            button(1, "hand.thumbsup", request.upvotes, Palette.mintText)
            button(-1, "hand.thumbsdown", request.downvotes, Palette.orange)
        }
    }

    private func button(_ value: Int, _ icon: String, _ count: Int, _ color: Color) -> some View {
        let mine = myVote == value
        return Button { vote(value) } label: {
            VStack(spacing: 2) {
                Image(systemName: mine ? icon + ".fill" : icon).font(.system(size: 15, weight: .semibold))
                Text("\(count)").font(.system(size: 12, weight: .bold))
            }
            .foregroundStyle(mine ? .white : color)
            .frame(width: 52, height: 50)
            .background(mine ? color : Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mine ? "Take back your vote" : value == 1 ? "I want this" : "I don't want this")
    }
}

/// One request in full, like a post: headline, the whole text, every picture, then comments.
private struct RequestDetail: View {
    let request: FeatureRequest
    @ObservedObject var store: FeatureRequestStore
    @ObservedObject var account: Account
    let theme: HomeTheme
    let back: () -> Void
    @State private var draft = ""
    @State private var sending = false
    @State private var confirmDelete = false
    @State private var commentToDelete: RequestComment?

    var body: some View {
        content
            .alert("Delete this request?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive, action: deleteRequest)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(request.title)\" and its votes, comments and pictures will be deleted for everyone. This can't be undone.")
            }
            .alert("Delete this comment?", isPresented: Binding(get: { commentToDelete != nil }, set: { if !$0 { commentToDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let comment = commentToDelete { Task { await store.deleteComment(comment, on: request) } }
                    commentToDelete = nil
                }
                Button("Cancel", role: .cancel) { commentToDelete = nil }
            } message: {
                Text("It will be deleted for everyone.")
            }
    }

    private var content: some View {
        PageBody {
            WhitePanel {
                HStack {
                    PillButton(title: "All requests", systemImage: "chevron.left", style: .ink, action: back)
                    Spacer()
                    if store.canDelete(authorID: request.author_id) {
                        PillButton(title: "Delete", systemImage: "trash", style: .outline) { confirmDelete = true }
                            .foregroundStyle(Palette.orange)
                    }
                    VoteButtons(request: request, myVote: store.myVotes[request.id]) { store.vote(request, $0) }
                }
                HStack(spacing: 10) {
                    Avatar(url: request.author_avatar)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(request.author_name ?? "MicFlow user").font(.system(size: 13, weight: .semibold))
                        Text(request.created_at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11)).foregroundStyle(Palette.greyOnLight)
                    }
                }
                Text(request.title).font(.display(30))
                Text(request.body).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(request.images, id: \.self) { path in
                    AsyncImage(url: Backend.publicFileURL(path)) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF2F2F0)).frame(height: 220)
                            .overlay(ProgressView())
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .foregroundStyle(Palette.ink)
            WhitePanel {
                Text("Comments").font(.display(22))
                let list = store.comments[request.id] ?? []
                if list.isEmpty { Text("No comments yet.").font(.system(size: 13)).foregroundStyle(Palette.greyOnLight) }
                ForEach(list) { comment in
                    HStack(alignment: .top, spacing: 10) {
                        Avatar(url: comment.author_avatar)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(comment.author_name ?? "MicFlow user").font(.system(size: 12, weight: .semibold))
                                Text(comment.created_at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11)).foregroundStyle(Palette.greyOnLight)
                            }
                            Text(comment.body).font(.system(size: 13)).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if store.canDelete(authorID: comment.author_id) {
                            Button { commentToDelete = comment } label: {
                                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Palette.greyOnLight)
                            }
                            .buttonStyle(.plain).help("Delete this comment")
                        }
                    }
                }
                if account.isSignedIn {
                    HStack {
                        PillField(placeholder: "Write a comment", text: $draft, onDark: false, onSubmit: send)
                        PillButton(title: sending ? "Sending…" : "Comment", style: .yellow, action: send)
                    }
                } else {
                    PillButton(title: "Sign in with Google to comment", systemImage: "person.crop.circle", style: .ink) {
                        account.signIn(setUpKey: false)
                    }
                }
            }
            .foregroundStyle(Palette.ink)
        }
    }

    private func deleteRequest() {
        Task { if await store.delete(request) { back() } }
    }

    private func send() {
        guard !sending, !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sending = true
        Task {
            if await store.addComment(draft, to: request) { draft = "" }
            sending = false
        }
    }
}

private struct Avatar: View {
    let url: String?

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Palette.cream).overlay(Image(systemName: "person.fill").foregroundStyle(Palette.pink))
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
    }
}

/// Write a request: a headline, the details, and pictures if they help.
private struct ComposeRequest: View {
    @ObservedObject var store: FeatureRequestStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var images: [Data] = []
    @State private var posting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request a feature").font(.title2.bold())
            TextField("Headline, e.g. \"Dictate in Hindi too\"", text: $title).textFieldStyle(.roundedBorder).font(.title3)
            Text("Details").font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Add pictures…", action: choose)
                Text(images.isEmpty ? "Optional" : "\(images.count) picture\(images.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                if !images.isEmpty { Button("Remove all") { images = [] } }
            }
            ScrollView(.horizontal) {
                HStack {
                    ForEach(images.indices, id: \.self) { index in
                        if let image = NSImage(data: images[index]) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 90, height: 64).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            if title.trimmingCharacters(in: .whitespaces).count < 4 {
                Text("Add a headline of at least 4 letters to post.").font(.caption).foregroundStyle(.secondary)
            }
            if let error = store.error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(posting ? "Posting…" : "Post") {
                    posting = true
                    Task {
                        if await store.post(title: title.trimmingCharacters(in: .whitespaces), body: text, images: images) { dismiss() }
                        posting = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(posting || title.trimmingCharacters(in: .whitespaces).count < 4)
            }
        }
        .padding(22)
        .frame(width: 560, height: 560)
    }

    /// Up to 6 pictures, each resized to at most 1600 px and saved as JPEG.
    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls.prefix(6 - images.count) {
            if let data = Self.jpeg(url) { images.append(data) }
        }
    }

    static func jpeg(_ url: URL) -> Data? {
        guard let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let scale = min(1, 1600 / Double(max(rep.pixelsWide, rep.pixelsHigh, 1)))
        let size = NSSize(width: Double(rep.pixelsWide) * scale, height: Double(rep.pixelsHigh) * scale)
        guard let resized = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return resized.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

/// Settings › General: sign in with Google (optional).
struct AccountCard: View {
    @ObservedObject var account: Account
    let theme: HomeTheme

    var body: some View {
        FeatureCard(theme: theme, systemImage: "person.crop.circle.fill", title: "Account",
                    subtitle: account.isSignedIn ? (account.user?.email ?? "Signed in") : "Optional") {
            if !account.isConfigured {
                Note(text: "Accounts are coming soon. Everything works without one.")
            } else if account.isSignedIn {
                HStack(spacing: 10) {
                    AsyncImage(url: account.user?.avatar.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: { Circle().fill(Palette.cream) }
                    .frame(width: 34, height: 34).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.user?.name ?? "Signed in").font(.system(size: 13, weight: .semibold))
                        Text(account.user?.email ?? "").font(.system(size: 11)).foregroundStyle(Palette.greyOnDark)
                    }
                    Spacer()
                    PillButton(title: "Sign out", style: .outline, action: account.signOut)
                }
                Note(text: "Your instructions, words, mix-ups and API key are saved to your account, so they come back if you reinstall MicFlow or use another Mac. Only your sign-in can read them back, though the app's maker runs the database and could technically see them.")
            } else {
                // No key yet: signing in also makes one, so Google's screens are explained first.
                PillButton(title: account.isWorking ? "Signing in…" : "Sign in with Google", systemImage: "person.crop.circle",
                           style: .cream) { account.wantsKeySetup() ? account.keySetup.begin() : account.signIn(setUpKey: false) }
                Note(text: "Optional. Signing in saves your instructions, words, mix-ups and API key to your account, and lets you post feature requests and comments. No API key yet? Signing in also sets one up for you.")
            }
            if let message = account.message { Note(text: message, isError: true) }
            KeySetupStatus(flow: account.keySetup)
        }
    }
}
