import Foundation

/// Google Photos 원본 사진·동영상 다운로드를 테스트에서 대체할 수 있도록 하는 최소 추상화.
/// 프로덕션에서는 `URLSession.download(for:)`를 사용해 바이트를 메모리에 적재하지 않고
/// 디스크 임시 파일로만 받는다.
protocol GooglePhotosContentDownloader: Sendable {
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

extension URLSession: GooglePhotosContentDownloader {
    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await download(for: request, delegate: nil)
    }
}

/// Picker의 Bearer 인증 콘텐츠 요청 구성과 다운로드 primitive를 묶는다.
/// 세션 ID·baseUrl·토큰은 어디에도 영속 저장하지 않는다.
struct GooglePhotosContentDownloadService: Sendable {
    let pickerClient: GooglePhotosPickerClient
    let downloader: any GooglePhotosContentDownloader

    init(
        pickerClient: GooglePhotosPickerClient,
        downloader: any GooglePhotosContentDownloader = URLSession.shared
    ) {
        self.pickerClient = pickerClient
        self.downloader = downloader
    }

    /// URLSession이 관리하는 임시 파일의 URL을 반환한다. 시스템이 파일을 정리하기 전에
    /// 서스펜션 없이 곧바로 소비해야 한다(호출자는 반환 즉시 사용해야 한다).
    func download(for item: GooglePhotosPickedMediaItem) async throws -> URL {
        let request = try await pickerClient.contentRequest(for: item)
        let (tempURL, response) = try await downloader.download(for: request)
        try GooglePhotosPickerError.validate(response)
        return tempURL
    }
}
