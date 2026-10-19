extension SFTPController {
    func showcaseListing(path: String) {
        requested = true
        remotePath = path == "." ? "/home/cisco.ramon" : path
        remoteFiles = Self.showcaseFiles
        recordRemoteVisit(remotePath)
        message = "\(remoteFiles.count) server items"
    }
    static var showcaseFiles: [TransferFile] {
        [
            TransferFile(name: "Archives", directory: true, regular: false, size: 0),
            TransferFile(name: "Projects", directory: true, regular: false, size: 0),
            TransferFile(name: "Reports", directory: true, regular: false, size: 0),
            TransferFile(name: "Telemetry", directory: true, regular: false, size: 0),
            TransferFile(name: "deployment.yml", directory: false, regular: true, size: 2840),
            TransferFile(name: "network-topology.pdf", directory: false, regular: true, size: 248320),
            TransferFile(name: "research-notes.md", directory: false, regular: true, size: 12840),
            TransferFile(name: "sensor-readings.csv", directory: false, regular: true, size: 842000),
            TransferFile(name: "weekly-report.pdf", directory: false, regular: true, size: 1_248_000),
        ]
    }
}
