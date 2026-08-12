import Foundation

enum RemoteFileServiceFactory {
    static func make(
        connection: RemoteConnection,
        credential: RemoteCredential
    ) -> any RemoteFileService {
        switch connection.kind {
        case .synology:
            SynologyFileService(connection: connection, credential: credential)
        case .sftp:
            SFTPFileService(connection: connection, credential: credential)
        case .smb:
            SMBFileService(connection: connection, credential: credential)
        case .webDAV:
            WebDAVFileService(connection: connection, credential: credential)
        case .ftp:
            FTPFileService(connection: connection, credential: credential)
        }
    }
}
