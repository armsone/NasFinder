import Foundation
import XCTest
@testable import NasFinder

final class GooglePhotosContentDownloadServiceTests: XCTestCase {
    private func makeItem(type: GooglePhotosMediaType, baseURL: String = "https://lh3.googleusercontent.com/p/x") -> GooglePhotosPickedMediaItem {
        GooglePhotosPickedMediaItem(
            id: "item-1",
            createTime: nil,
            type: type,
            mediaFile: GooglePhotosMediaFile(
                baseURL: baseURL,
                mimeType: type == .video ? "video/mp4" : "image/jpeg",
                filename: type == .video ? "clip.mp4" : "photo.jpg",
                metadata: nil
            )
        )
    }

    func testDownloadUsesBearerAuthorizedContentRequestAndReturnsTempFile() async throws {
        let downloader = GooglePhotosContentDownloaderMock(stubs: [.success(fileContents: Data("bytes".utf8))])
        defer { downloader.cleanUpCreatedTempFiles() }
        let pickerClient = GooglePhotosPickerClient(httpClient: GooglePhotosHTTPClientMock()) { "test-token" }
        let service = GooglePhotosContentDownloadService(pickerClient: pickerClient, downloader: downloader)

        let tempURL = try await service.download(for: makeItem(type: .video))

        let request = try XCTUnwrap(downloader.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://lh3.googleusercontent.com/p/x=dv")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(try Data(contentsOf: tempURL), Data("bytes".utf8))
    }

    func testDownloadMapsHTTPErrorWithoutExposingSensitiveDetails() async throws {
        let downloader = GooglePhotosContentDownloaderMock(stubs: [.success(fileContents: Data(), statusCode: 401)])
        defer { downloader.cleanUpCreatedTempFiles() }
        let pickerClient = GooglePhotosPickerClient(httpClient: GooglePhotosHTTPClientMock()) { "test-token" }
        let service = GooglePhotosContentDownloadService(pickerClient: pickerClient, downloader: downloader)

        do {
            _ = try await service.download(for: makeItem(type: .photo))
            XCTFail("401 응답이 오류로 매핑되어야 합니다.")
        } catch let error as GooglePhotosPickerError {
            XCTAssertEqual(error, .http(statusCode: 401, category: .unauthorized))
        }
    }

    func testDownloadPropagatesTransportFailure() async throws {
        struct DummyError: Error {}
        let downloader = GooglePhotosContentDownloaderMock(stubs: [.failure(DummyError())])
        defer { downloader.cleanUpCreatedTempFiles() }
        let pickerClient = GooglePhotosPickerClient(httpClient: GooglePhotosHTTPClientMock()) { "test-token" }
        let service = GooglePhotosContentDownloadService(pickerClient: pickerClient, downloader: downloader)

        do {
            _ = try await service.download(for: makeItem(type: .photo))
            XCTFail("전송 오류가 전파되어야 합니다.")
        } catch is DummyError {
            // expected
        }
    }
}
