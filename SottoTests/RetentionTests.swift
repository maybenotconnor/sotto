import Foundation
import Testing
@testable import Sotto

struct RetentionTests {
    private func tempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetentionTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func settingsDefaultToDeleteAfterTranscription() {
        let suite = UserDefaults(suiteName: "retention-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        #expect(settings.audioRetention == .deleteAfterTranscription)
        settings.audioRetention = .keepSevenDays
        #expect(settings.audioRetention == .keepSevenDays)
    }

    @Test func listeningSettingsDefaultsMatchSpec() {
        let suite = UserDefaults(suiteName: "settings-tests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        #expect(settings.vadThreshold == 0.6)
        #expect(settings.silenceTimeout == 45)
        #expect(settings.minSegmentSpeech == 3)
        #expect(settings.preRollSeconds == 1.0)
        #expect(settings.wifiOnlyUpload == true)
        #expect(settings.deepgramEnabled == false)
        settings.vadThreshold = 0.4
        settings.silenceTimeout = 90
        #expect(settings.vadThreshold == Float(0.4))
        #expect(settings.silenceTimeout == 90)
    }

    @Test func applyAfterTranscriptionDeletesOnlyUnderDefaultPolicy() throws {
        let root = tempRoot()
        for retention in AudioRetention.allCases {
            let url = root.appendingPathComponent("\(retention.rawValue).m4a")
            try Data([0x01]).write(to: url)
            let deleted = RetentionEnforcer.applyAfterTranscription(m4aURL: url, retention: retention)
            #expect(deleted == (retention == .deleteAfterTranscription))
            #expect(FileManager.default.fileExists(atPath: url.path) == !deleted)
        }
    }

    @Test func sevenDaySweepDeletesOldTranscribedAudioOnly() throws {
        let root = tempRoot()
        let day = root.appendingPathComponent("2026-01-01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let oldDone = day.appendingPathComponent("01-00-00.m4a")
        let oldPending = day.appendingPathComponent("02-00-00.m4a")
        try Data([1]).write(to: oldDone)
        try Data([1]).write(to: oldPending)
        try "x".write(to: day.appendingPathComponent("01-00-00.md"), atomically: true, encoding: .utf8)
        let past = Date(timeIntervalSinceNow: -8 * 86_400)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: oldDone.path)
        try FileManager.default.setAttributes([.creationDate: past], ofItemAtPath: oldPending.path)

        let deleted = RetentionEnforcer.sweep(root: root, retention: .keepSevenDays)

        #expect(deleted == [oldDone])                        // transcribed + old → deleted
        #expect(FileManager.default.fileExists(atPath: oldPending.path))   // never delete untranscribed
        // Other policies sweep nothing:
        #expect(RetentionEnforcer.sweep(root: root, retention: .keepForever).isEmpty)
        #expect(RetentionEnforcer.sweep(root: root, retention: .deleteAfterTranscription).isEmpty)
    }

    @Test func corruptedSettingsClampToSpecRanges() {
        let suite = UserDefaults(suiteName: "settings-clamp-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: suite)
        suite.set(Float.nan, forKey: "vadThreshold")
        suite.set(-5.0, forKey: "silenceTimeout")
        suite.set(9_999.0, forKey: "preRollSeconds")
        suite.set(0.0, forKey: "minSegmentSpeech")
        #expect(settings.vadThreshold == 0.6)
        #expect(settings.silenceTimeout == 15)
        #expect(settings.preRollSeconds == 3.0)
        #expect(settings.minSegmentSpeech == 1)
    }

    @Test func transcodedM4AIsExcludedFromBackup() throws {
        let root = tempRoot()
        let caf = root.appendingPathComponent("a.caf")
        let m4a = root.appendingPathComponent("a.m4a")
        let writer = try CAFSegmentWriter(cafURL: caf, m4aURL: m4a)
        try writer.append([Float](repeating: 0.1, count: VADConstants.sampleRate))
        writer.close()
        try CAFSegmentWriter.transcodeToM4A(caf: caf, m4a: m4a)
        let values = try m4a.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)         // SPEC backup policy: audio excluded
    }
}
