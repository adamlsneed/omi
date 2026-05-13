import XCTest

@testable import Omi_Computer

final class TranscriptionServiceChannelTests: XCTestCase {
    func testConversationServiceCanBeConfiguredForTwoChannels() throws {
        let service = try TranscriptionService(language: "en", mode: .conversation, channels: 2)

        XCTAssertEqual(service.configuredChannels, 2)
    }

    func testChannelAudioPayloadPrefixesChannelByte() {
        let audio = Data([0x10, 0x20, 0x30])

        XCTAssertEqual(
            TranscriptionService.framedAudioPayload(audio, channel: .mic),
            Data([0x01, 0x10, 0x20, 0x30])
        )
        XCTAssertEqual(
            TranscriptionService.framedAudioPayload(audio, channel: .systemAudio),
            Data([0x02, 0x10, 0x20, 0x30])
        )
    }
}
