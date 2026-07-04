import AVFoundation
import Testing
@testable import Sotto

struct AudioSessionTests {
    @Test func configuresPlayAndRecordWithMixWithOthers() throws {
        try PhoneMicAudioSource.configureSession()
        let session = AVAudioSession.sharedInstance()
        #expect(session.category == .playAndRecord)
        #expect(session.categoryOptions.contains(.mixWithOthers))
    }
}
