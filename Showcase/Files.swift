extension SFTPController {
    func showcaseListing(path: String) {
        requested = true
        remotePath = path == "." ? ShowcaseLibrary.sftp.remote.path : path
        remoteFiles = ShowcaseLibrary.sftp.remote.files(at: remotePath)
        recordRemoteVisit(remotePath)
        message = "\(remoteFiles.count) server items"
    }
}
