// UUIDs and framing constants from BasedHardware/omi (MIT) — firmware transport.c and
// app models.dart. See docs/superpowers/specs/2026-07-06-omi-devkit2-audio-source-design.md.
import Foundation

enum OmiConstants {
    static let audioServiceUUID = "19B10000-E8F2-537E-4F6C-D104768A1214"
    static let audioDataCharacteristicUUID = "19B10001-E8F2-537E-4F6C-D104768A1214"
    static let codecCharacteristicUUID = "19B10002-E8F2-537E-4F6C-D104768A1214"
    static let batteryServiceUUID = "180F"
    static let batteryLevelCharacteristicUUID = "2A19"
    static let deviceInfoServiceUUID = "180A"
    static let firmwareRevisionCharacteristicUUID = "2A26"

    static let notificationHeaderSize = 3
    /// One Opus frame at the firmware's documented worst case (20 ms @ 16 kHz). Used to
    /// size the silence fill for a dropped packet.
    static let samplesPerFrame = 320
    /// Codec characteristic values (char 19B10002). 8 kHz variants are rejected (spec).
    static let codecPCM16at16kHz: UInt8 = 0
    static let codecPCM16at8kHz: UInt8 = 1
    static let codecMuLawAt16kHz: UInt8 = 10
    static let codecMuLawAt8kHz: UInt8 = 11
    static let codecOpusAt16kHz: UInt8 = 20

    static let lowBatteryThresholdPercent = 15
}
