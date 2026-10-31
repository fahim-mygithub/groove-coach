import SwiftUI
import UniformTypeIdentifiers

/// Course and lesson catalog browser:
/// - Course -> Lesson -> Segments (A, B, C, D and Full Run),
/// - Downloads lesson packages atomically with SHA-256 validation,
/// - DEV MODE: Ingests lesson packages directly from a folder in the Files app,
/// - Email OTP login sheet for Supabase auth.
public struct CourseListView: View {
    @EnvironmentObject private var lessonStore: LessonStore
    @StateObject private var supabase = SupabaseClient.shared

    @State private var showFileImporter: Bool = false
    @State private var showAuthSheet: Bool = false
    @State private var bannerMessage: String?
    @State private var isErrorMessage: Bool = false

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                // Banner / status notifications
                if let message = bannerMessage {
                    Section {
                        HStack {
                            Image(systemName: isErrorMessage ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .foregroundStyle(isErrorMessage ? .orange : .green)
                            Text(message)
                                .font(.footnote)
                            Spacer()
                            Button {
                                bannerMessage = nil
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Dev Mode Quick Action Card
                Section("Developer Mode (No Backend Needed)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Load a lesson package directory containing manifest.json and media files directly from the Files app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                showFileImporter = true
                            } label: {
                                Label("Import Folder from Files", systemImage: "folder.badge.plus")
                                    .font(.subheadline.bold())
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                seedFilmiRoutineDevPackage()
                            } label: {
                                Label("Load Demo Lesson", systemImage: "sparkles")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Courses Section
                Section("Available Courses") {
                    if groupedCourses.isEmpty {
                        Text("No courses found. Tap Refresh or import a folder in Dev Mode.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groupedCourses, id: \.slug) { course in
                            NavigationLink {
                                CourseDetailView(course: course)
                            } label: {
                                CourseRowView(course: course)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Courses")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAuthSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: supabase.isAuthenticated ? "person.crop.circle.badge.checkmark" : "person.crop.circle")
                            Text(supabase.isAuthenticated ? "Account" : "Sign In")
                                .font(.caption.bold())
                        }
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refreshCatalog() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .sheet(isPresented: $showAuthSheet) {
                SupabaseAuthSheet()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFileImporter(result: result)
            }
        }
    }

    // MARK: - Helpers

    private var groupedCourses: [CourseGroup] {
        let items = lessonStore.catalog
        var dict: [String: [CatalogItem]] = [:]
        for item in items {
            dict[item.course_slug, default: []].append(item)
        }
        return dict.map { slug, items in
            let title = items.first?.course_title ?? slug.capitalized
            return CourseGroup(slug: slug, title: title, items: items.sorted(by: { ($0.position ?? 0) < ($1.position ?? 0) }))
        }.sorted(by: { $0.title < $1.title })
    }

    private func handleFileImporter(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let folderURL = urls.first else { return }
            do {
                let manifest = try lessonStore.importPackageFromFolder(folderURL: folderURL)
                bannerMessage = "Successfully imported '\(manifest.title)' from Files app!"
                isErrorMessage = false
            } catch {
                bannerMessage = "Import failed: \(error.localizedDescription)"
                isErrorMessage = true
            }
        case .failure(let error):
            bannerMessage = "Folder selection failed: \(error.localizedDescription)"
            isErrorMessage = true
        }
    }

    private func seedFilmiRoutineDevPackage() {
        let sample = LessonManifest.makeSampleFilmiManifest()
        let dir = lessonStore.lessonVersionDirectory(lessonId: sample.lesson_id, version: sample.package_version)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sample) {
            try? data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        }
        bannerMessage = "Demo lesson '\(sample.title)' initialized for offline inspection."
        isErrorMessage = false
    }

    private func refreshCatalog() async {
        do {
            try await lessonStore.refreshCatalog()
            bannerMessage = "Catalog refreshed."
            isErrorMessage = false
        } catch {
            bannerMessage = "Catalog refresh failed: \(error.localizedDescription)"
            isErrorMessage = true
        }
    }
}

// MARK: - Course Models & Rows

struct CourseGroup: Identifiable {
    var id: String { slug }
    let slug: String
    let title: String
    let items: [CatalogItem]
}

struct CourseRowView: View {
    let course: CourseGroup

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "figure.dance.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.indigo)

            VStack(alignment: .leading, spacing: 4) {
                Text(course.title)
                    .font(.headline)
                Text("\(course.items.count) lesson\(course.items.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Course Detail (Lessons list)

struct CourseDetailView: View {
    let course: CourseGroup

    var body: some View {
        List {
            Section("Course Overview") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(course.title)
                        .font(.title2.bold())
                    Text("Slug: \(course.slug)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section("Lessons") {
                ForEach(course.items) { item in
                    NavigationLink {
                        LessonDetailView(item: item)
                    } label: {
                        LessonRowView(item: item)
                    }
                }
            }
        }
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LessonRowView: View {
    let item: CatalogItem
    @EnvironmentObject private var lessonStore: LessonStore

    var isDownloaded: Bool {
        lessonStore.isLessonDownloaded(lessonId: item.lesson_id, version: item.package_version)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(isDownloaded ? .green : .blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.lesson_title)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text("v\(item.package_version)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2), in: Capsule())
                    Text(isDownloaded ? "Downloaded (Local)" : "Ready to download")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Lesson Detail (Segments: A, B, C, D, Full Run)

struct LessonDetailView: View {
    let item: CatalogItem
    @EnvironmentObject private var lessonStore: LessonStore

    @State private var activeSegment: LessonManifest.SegmentInfo?
    @State private var isDownloading: Bool = false
    @State private var downloadError: String?

    var manifest: LessonManifest {
        item.manifest ?? lessonStore.loadManifest(lessonId: item.lesson_id, version: item.package_version) ?? LessonManifest.makeSampleFilmiManifest()
    }

    var isDownloaded: Bool {
        lessonStore.isLessonDownloaded(lessonId: item.lesson_id, version: item.package_version)
    }

    var body: some View {
        List {
            // Header
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(manifest.title)
                        .font(.title2.bold())
                    Text("Course: \(manifest.course_slug) • Version \(manifest.package_version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 16) {
                        Label(String(format: "%.1f BPM", manifest.beat_grid.bpm), systemImage: "metronome")
                        Label(String(format: "%.1fs", manifest.video.duration_s), systemImage: "clock")
                        Label("\(manifest.segments.count) parts", systemImage: "list.number")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !isDownloaded {
                        Button {
                            Task { await downloadPackage() }
                        } label: {
                            HStack {
                                Spacer()
                                if isDownloading {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Label("Download Lesson Package", systemImage: "arrow.down.circle.fill")
                                        .font(.subheadline.bold())
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDownloading)
                    } else {
                        HStack {
                            Image(systemName: "externaldrive.badge.checkmark")
                                .foregroundStyle(.green)
                            Text("Package installed in Application Support (excluded from backup).")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let err = downloadError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 4)
            }

            // Segments in teaching order A -> B -> C -> D -> full
            Section("Teaching Order: Segments & Full Run") {
                ForEach(sortedSegments) { segment in
                    SegmentRowView(segment: segment) {
                        activeSegment = segment
                    }
                }
            }
        }
        .navigationTitle(item.lesson_title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $activeSegment) { segment in
            LessonPlayerView(
                manifest: manifest,
                segment: segment,
                videoURL: lessonStore.localVideoURL(for: manifest)
            )
        }
    }

    private var sortedSegments: [LessonManifest.SegmentInfo] {
        manifest.segments.sorted(by: { $0.teach_order < $1.teach_order })
    }

    private func downloadPackage() async {
        isDownloading = true
        downloadError = nil
        do {
            _ = try await lessonStore.downloadLesson(item: item)
        } catch {
            downloadError = error.localizedDescription
        }
        isDownloading = false
    }
}

// MARK: - Segment Row View

struct SegmentRowView: View {
    let segment: LessonManifest.SegmentInfo
    let onPlay: () -> Void

    var isFullRun: Bool {
        segment.kind == "full_run" || segment.id.lowercased() == "full"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Segment Badge
                Text(isFullRun ? "FULL" : segment.id)
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isFullRun ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(isFullRun ? .purple : .blue)

                Text(segment.title)
                    .font(.headline)

                Spacer()

                Button {
                    onPlay()
                } label: {
                    Label("Practice", systemImage: "play.fill")
                        .font(.caption.bold())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Text(String(format: "%.2f–%.2fs", segment.start_s, segment.end_s))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let difficulty = segment.difficulty {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= difficulty ? "star.fill" : "star")
                                .font(.system(size: 8))
                                .foregroundStyle(star <= difficulty ? .orange : .secondary.opacity(0.3))
                        }
                    }
                }

                if let focus = segment.focus {
                    Text(focus.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let cues = segment.cues, !cues.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(cues, id: \.self) { cue in
                        HStack(alignment: .top, spacing: 4) {
                            Text("•")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(cue)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Supabase Auth Sheet

struct SupabaseAuthSheet: View {
    @StateObject private var client = SupabaseClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var email: String = ""
    @State private var otpCode: String = ""
    @State private var otpSent: Bool = false
    @State private var statusMessage: String?
    @State private var isError: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = client.currentSession?.user {
                    Section("Signed In") {
                        LabeledContent("User ID", value: user.id)
                        if let userEmail = user.email {
                            LabeledContent("Email", value: userEmail)
                        }
                        Button("Sign Out", role: .destructive) {
                            client.signOut()
                            statusMessage = "Signed out."
                        }
                    }
                } else {
                    Section("Email Magic OTP Login") {
                        TextField("Learner email address", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task { await sendOTP() }
                        } label: {
                            if client.isBusy && !otpSent {
                                ProgressView()
                            } else {
                                Text(otpSent ? "Resend 6-Digit Code" : "Send OTP Code")
                            }
                        }
                        .disabled(email.isEmpty || client.isBusy)
                    }

                    if otpSent {
                        Section("Verify Code") {
                            TextField("6-digit code", text: $otpCode)
                                .keyboardType(.numberPad)

                            Button {
                                Task { await verifyOTP() }
                            } label: {
                                if client.isBusy {
                                    ProgressView()
                                } else {
                                    Text("Verify & Sign In")
                                }
                            }
                            .disabled(otpCode.count < 6 || client.isBusy)
                        }
                    }
                }

                if let message = statusMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(isError ? .red : .green)
                    }
                }
            }
            .navigationTitle("Supabase Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func sendOTP() async {
        statusMessage = nil
        do {
            try await client.sendEmailOTP(email: email)
            otpSent = true
            isError = false
            statusMessage = "OTP code sent to \(email)."
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }

    private func verifyOTP() async {
        statusMessage = nil
        do {
            _ = try await client.verifyEmailOTP(email: email, token: otpCode)
            isError = false
            statusMessage = "Successfully verified and signed in!"
        } catch {
            isError = true
            statusMessage = error.localizedDescription
        }
    }
}
