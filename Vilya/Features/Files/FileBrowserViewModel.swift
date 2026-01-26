import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
class FileBrowserViewModel {
    var files: [FileItem] = []
    var currentPath = "~"
    var isLoading = false
    var errorMessage: String?
    var showHiddenFiles = false
    var selectedFile: FileItem?
    var activeTransfers: [FileTransfer] = []
    var showCreateFolder = false
    var newFolderName = ""

    private var pathHistory: [String] = []
    private var sshService: SSHService?

    var canGoBack: Bool { !pathHistory.isEmpty }
    var currentDirectoryName: String { currentPath == "~" || currentPath == "/" ? "Home" : (currentPath as NSString).lastPathComponent }
    var filteredFiles: [FileItem] {
        (showHiddenFiles ? files : files.filter { !$0.name.hasPrefix(".") })
            .sorted { ($0.isDirectory && !$1.isDirectory) || ($0.isDirectory == $1.isDirectory && $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending) }
    }

    func setSSHService(_ service: SSHService) { self.sshService = service }

    func loadDirectory() async { await navigateTo(currentPath) }

    func navigateTo(_ path: String) async {
        guard let sshService = sshService else { errorMessage = "Not connected"; return }
        isLoading = true; errorMessage = nil
        do {
            var expandedPath = path
            if path.hasPrefix("~") { expandedPath = path.replacingOccurrences(of: "~", with: try await sshService.execute("echo $HOME").trimmingCharacters(in: .whitespacesAndNewlines)) }
            try await sshService.openSFTP()
            let items = try await sshService.listDirectory(expandedPath)
            if path != currentPath { pathHistory.append(currentPath) }
            currentPath = expandedPath; files = items
        } catch { errorMessage = error.localizedDescription }
        isLoading = false
    }

    func goBack() async {
        guard let prev = pathHistory.popLast() else { return }
        await navigateTo(prev); _ = pathHistory.popLast()
    }

    func refresh() async { let p = currentPath; await navigateTo(p); _ = pathHistory.popLast() }

    func createFolder() async {
        guard let sshService = sshService, !newFolderName.isEmpty else { return }
        do { try await sshService.createDirectory((currentPath as NSString).appendingPathComponent(newFolderName)); newFolderName = ""; await refresh() }
        catch { errorMessage = "Failed to create folder: \(error.localizedDescription)" }
    }

    func delete(_ item: FileItem) async {
        guard let sshService = sshService else { return }
        do { try await sshService.delete(item.path, isDirectory: item.isDirectory); files.removeAll { $0.id == item.id } }
        catch { errorMessage = "Failed to delete: \(error.localizedDescription)" }
    }

    func readFile(_ file: FileItem) async throws -> Data {
        guard let sshService = sshService else { throw SSHError.notConnected }
        return try await sshService.readFile(file.path)
    }

    func downloadFile(_ file: FileItem) async {
        guard let sshService = sshService else { return }
        let localPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(file.name).path
        let transfer = FileTransfer(fileName: file.name, remotePath: file.path, localPath: localPath, isUpload: false, totalBytes: file.size)
        activeTransfers.append(transfer)
        do {
            transfer.status = .inProgress
            try await sshService.downloadFile(remotePath: file.path, localPath: localPath) { curr, _ in Task { @MainActor in transfer.transferredBytes = curr } }
            transfer.status = .completed
            NotificationService.shared.notifyTransferComplete(fileName: file.name, isUpload: false, success: true)
        } catch { transfer.status = .failed; transfer.error = error.localizedDescription }
        try? await Task.sleep(nanoseconds: 3_000_000_000); activeTransfers.removeAll { $0.id == transfer.id }
    }

    func uploadFile(from localURL: URL) async {
        guard let sshService = sshService else { return }
        let fileName = localURL.lastPathComponent
        let remotePath = (currentPath as NSString).appendingPathComponent(fileName)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        let transfer = FileTransfer(fileName: fileName, remotePath: remotePath, localPath: localURL.path, isUpload: true, totalBytes: fileSize)
        activeTransfers.append(transfer)
        do {
            transfer.status = .inProgress
            guard localURL.startAccessingSecurityScopedResource() else { throw NSError(domain: "FileBrowser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot access file"]) }
            defer { localURL.stopAccessingSecurityScopedResource() }
            try await sshService.uploadFile(localPath: localURL.path, remotePath: remotePath) { curr, _ in Task { @MainActor in transfer.transferredBytes = curr } }
            transfer.status = .completed; await refresh()
            NotificationService.shared.notifyTransferComplete(fileName: fileName, isUpload: true, success: true)
        } catch { transfer.status = .failed; transfer.error = error.localizedDescription }
        try? await Task.sleep(nanoseconds: 3_000_000_000); activeTransfers.removeAll { $0.id == transfer.id }
    }
}
