import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @Environment(AppState.self) var appState
    @State private var viewModel = FileBrowserViewModel()
    @State private var showUploadPicker = false
    @State private var selectedFile: FileItem?

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading && viewModel.files.isEmpty { ProgressView("Loading...") }
                else if let error = viewModel.errorMessage { VStack { Image(systemName: "exclamationmark.triangle").font(.system(size: 40)); Text(error); Button("Retry") { Task { await viewModel.refresh() } } }.padding() }
                else { fileList }
            }
            .navigationTitle(viewModel.currentDirectoryName).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.canGoBack { Button { Task { await viewModel.goBack() } } label: { Image(systemName: "chevron.left") } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showUploadPicker = true } label: { Label("Upload File", systemImage: "arrow.up.doc") }
                        Button { viewModel.showCreateFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        Divider()
                        Button { Task { await viewModel.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button { viewModel.showHiddenFiles.toggle() } label: { Label(viewModel.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files", systemImage: viewModel.showHiddenFiles ? "eye.slash" : "eye") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showUploadPicker) { DocumentPicker { urls in Task { for url in urls { await viewModel.uploadFile(from: url) } } } }
            .alert("New Folder", isPresented: Binding(get: { viewModel.showCreateFolder }, set: { viewModel.showCreateFolder = $0 })) {
                TextField("Folder Name", text: Binding(get: { viewModel.newFolderName }, set: { viewModel.newFolderName = $0 }))
                Button("Cancel", role: .cancel) { viewModel.newFolderName = "" }
                Button("Create") { Task { await viewModel.createFolder() } }
            }
            .task { viewModel.setSSHService(appState.sshService); await viewModel.loadDirectory() }
        }
    }

    private var fileList: some View {
        List {
            Section { Text(viewModel.currentPath).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
            Section {
                ForEach(viewModel.filteredFiles) { item in
                    FileRow(item: item) {
                        if item.isDirectory { Task { await viewModel.navigateTo(item.path) } }
                        else { selectedFile = item }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { Task { await viewModel.delete(item) } } label: { Label("Delete", systemImage: "trash") }
                        if !item.isDirectory { Button { Task { await viewModel.downloadFile(item) } } label: { Label("Download", systemImage: "arrow.down.doc") }.tint(.blue) }
                    }
                }
            }
            if !viewModel.activeTransfers.isEmpty {
                Section("Transfers") { ForEach(viewModel.activeTransfers) { transfer in TransferRow(transfer: transfer) } }
            }
        }.listStyle(.insetGrouped).refreshable { await viewModel.refresh() }
        .sheet(item: $selectedFile) { file in FilePreviewSheet(file: file, viewModel: viewModel) }
    }
}

struct FileRow: View {
    let item: FileItem; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.iconName).font(.title2).foregroundStyle(item.isDirectory ? .blue : .secondary).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).foregroundColor(.primary).lineLimit(1)
                    Text(item.displaySize).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if item.isDirectory { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
        }.buttonStyle(.plain)
    }
}

struct TransferRow: View {
    var transfer: FileTransfer
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: transfer.isUpload ? "arrow.up.circle" : "arrow.down.circle").foregroundStyle(transfer.status == .completed ? .green : transfer.status == .failed ? .red : .blue)
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.fileName).lineLimit(1)
                ProgressView(value: transfer.progress)
                Text("\(Int(transfer.progress * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct FilePreviewSheet: View {
    let file: FileItem; var viewModel: FileBrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""; @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading { ProgressView() }
                else { ScrollView { Text(content).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).padding().textSelection(.enabled) } }
            }
            .navigationTitle(file.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button { Task { await viewModel.downloadFile(file) }; dismiss() } label: { Label("Download", systemImage: "arrow.down.doc") } }
            }
            .task {
                let ext = (file.name as NSString).pathExtension.lowercased()
                guard Constants.FileBrowser.supportedPreviewExtensions.contains(ext), file.size <= Constants.FileBrowser.maxPreviewSize else {
                    content = "Preview not available. Tap Download to save."; isLoading = false; return
                }
                do { content = String(data: try await viewModel.readFile(file), encoding: .utf8) ?? "Unable to decode" } catch { content = "Error: \(error.localizedDescription)" }
                isLoading = false
            }
        }
    }
}

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true; picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

#Preview { FileBrowserView().environment(AppState()) }
