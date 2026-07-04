import Foundation

/// Cloud transcription, BYOK (SPEC "DeepgramService"). Params per spec: nova-3,
/// diarize_model=latest (NEVER the deprecated diarize=true), utterances, smart_format,
/// and mip_opt_out=true always — the training opt-out is part of the privacy story.
struct DeepgramService: TranscriptionService {
    let backend = TranscriptionBackend.deepgram
    let apiKeyProvider: @Sendable () -> String?
    let session: URLSession

    init(apiKeyProvider: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.apiKeyProvider = apiKeyProvider
        self.session = session
    }

    func transcribe(file: URL) async throws -> TranscriptionResult {
        guard let key = apiKeyProvider() else { throw TranscriptionError.missingAPIKey }
        let audio = try Data(contentsOf: file)
        guard !audio.isEmpty else { throw TranscriptionError.emptyAudio }

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-3"),
            URLQueryItem(name: "diarize_model", value: "latest"),
            URLQueryItem(name: "utterances", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "mip_opt_out", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        request.httpBody = audio

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TranscriptionError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        let segments = (decoded.results.utterances ?? []).map { utterance in
            TranscriptionSegment(
                speaker: utterance.speaker.map { String($0 + 1) },   // 0-based → "Speaker 1"
                text: utterance.transcript,
                startTime: utterance.start,
                endTime: utterance.end)
        }
        let text = decoded.results.channels.first?.alternatives.first?.transcript
            ?? segments.map(\.text).joined(separator: " ")
        let duration = segments.last?.endTime ?? 0
        return TranscriptionResult(
            text: text, segments: segments, duration: duration, backend: backend)
    }
}

private struct DeepgramResponse: Decodable {
    struct Results: Decodable {
        struct Channel: Decodable {
            struct Alternative: Decodable { let transcript: String }
            let alternatives: [Alternative]
        }
        struct Utterance: Decodable {
            let start: TimeInterval
            let end: TimeInterval
            let transcript: String
            let speaker: Int?
        }
        let channels: [Channel]
        let utterances: [Utterance]?
    }
    let results: Results
}
