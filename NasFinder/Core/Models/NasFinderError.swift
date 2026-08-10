import Foundation

enum NasFinderError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case credentialsMissing
    case authenticationFailed
    case server(String)
    case unsupported(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .credentialsMissing: "저장된 로그인 정보가 없습니다."
        case .authenticationFailed: "아이디 또는 비밀번호를 확인해 주세요."
        case .server(let message): message
        case .unsupported(let message): message
        case .invalidResponse: "서버 응답을 해석할 수 없습니다."
        }
    }
}
