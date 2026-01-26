import Foundation
import Observation

struct FileItem: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedDate: Date?
    let permissions: String?

    var displaySize: String {
        isDirectory ? "--" : ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var iconName: String {
        if isDirectory { return "folder.fill" }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "py", "js", "ts", "go", "rs", "c", "cpp", "h", "java": return "doc.text.fill"
        case "json", "yaml", "yml", "toml", "xml": return "doc.badge.gearshape.fill"
        case "md", "txt": return "doc.plaintext.fill"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo.fill"
        case "zip", "tar", "gz": return "doc.zipper"
        case "sh", "bash": return "terminal.fill"
        default: return "doc.fill"
        }
    }

    init(name: String, path: String, isDirectory: Bool, size: Int64 = 0, modifiedDate: Date? = nil, permissions: String? = nil) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
        self.permissions = permissions
    }
}

@Observable
class FileTransfer: Identifiable {
    let id: UUID
    let fileName: String
    let remotePath: String
    let localPath: String
    let isUpload: Bool
    let totalBytes: Int64
    var transferredBytes: Int64 = 0
    var status: TransferStatus = .pending
    var error: String?

    var progress: Double { totalBytes > 0 ? Double(transferredBytes) / Double(totalBytes) : 0 }

    init(id: UUID = UUID(), fileName: String, remotePath: String, localPath: String, isUpload: Bool, totalBytes: Int64) {
        self.id = id
        self.fileName = fileName
        self.remotePath = remotePath
        self.localPath = localPath
        self.isUpload = isUpload
        self.totalBytes = totalBytes
    }
}

enum TransferStatus { case pending, inProgress, completed, failed, cancelled }
