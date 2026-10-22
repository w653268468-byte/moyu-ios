import SwiftUI
import AVFoundation
import MediaPlayer

@MainActor final class ReaderSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = ReaderSpeech()
    @Published private(set) var active = false
    @Published private(set) var paused = false
    @Published private(set) var loading = false
    @Published private(set) var owner = ""
    @Published private(set) var title = ""
    @Published private(set) var chapterIndex = 0
    @Published var message: String?
    private let synthesizer = AVSpeechSynthesizer()
    private var token = UUID()
    private var loadTask: Task<Void, Never>?, sleepTask: Task<Void, Never>?
    private var loader: ((Int) async throws -> (String, String)?)?
    private var positionMap: ((Int, Int, Bool) -> Int)?
    private var progress: ((Int, Int) -> Void)?
    private var chunks: [SpeechTextChunk] = []
    private var chunkIndex = 0
    private var speaking: AVSpeechUtterance?
    private var lastProgress = Date.distantPast
    private var resumeAfterInterruption = false
    private var chapterTitle = ""
    private var observers: [NSObjectProtocol] = []
    private let simulated: Bool
    init(simulated: Bool = false) {
        self.simulated = simulated
        super.init(); synthesizer.delegate = self; synthesizer.usesApplicationAudioSession = true
        if simulated { return }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        commands.stopCommand.addTarget { [weak self] _ in Task { @MainActor in self?.stop() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in guard let self, self.active else { return }; self.load(self.chapterIndex + 1, offset: 0) }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in guard let self, self.active else { return }; self.load(max(0, self.chapterIndex - 1), offset: 0) }; return .success }
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in Task { @MainActor in self?.interrupted(note) } })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in Task { @MainActor in self?.routeChanged(note) } })
    }
    func start(owner: String, title: String, chapter: Int, offset: Int,
               loader: @escaping (Int) async throws -> (String, String)?, positionMap: ((Int, Int, Bool) -> Int)? = nil, progress: @escaping (Int, Int) -> Void) {
        if active && self.owner == owner { toggle(); return }
        stop()
        do {
            if !simulated {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            }
        } catch { message = "无法开启听书音频：" + error.localizedDescription; return }
        self.owner = owner; self.title = title; self.loader = loader; self.positionMap = positionMap
        self.progress = { chapter, offset in progress(chapter, positionMap?(chapter, offset, true) ?? offset) }
        active = true; paused = false
        let minutes = min(180, max(0, UserDefaults.standard.integer(forKey: "reader.sleepMinutes")))
        if minutes > 0 { sleepTask = Task { try? await Task.sleep(for: .seconds(minutes * 60)); guard !Task.isCancelled else { return }; self.stop() } }
        load(chapter, offset: offset)
    }
    private func load(_ index: Int, offset: Int) {
        loadTask?.cancel(); token = UUID(); let current = token
        speaking = nil; synthesizer.stopSpeaking(at: .immediate); loading = true
        guard let loader else { stop(); return }
        loadTask = Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "Gavin 听书章节") { [weak self] in Task { @MainActor in self?.stop() } }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            do {
                guard let (name, text) = try await loader(index) else { if current == token { stop() }; return }
                try Task.checkCancellation(); guard current == token else { return }
                let value = SpeechText.chunks(text, startingAt: positionMap?(index, offset, false) ?? offset)
                guard !value.isEmpty else { stop(); message = "这一章没有可朗读的文字。"; return }
                chapterTitle = name; chapterIndex = index; chunks = value; chunkIndex = 0; loading = false
                progress?(index, value[0].utf16Offset)
                if !paused { speakChunk() }; updateNowPlaying()
            } catch {
                guard current == token, !Task.isCancelled else { return }
                stop(); message = "听书章节读取失败：" + error.localizedDescription
            }
        }
    }
    private func speakChunk() {
        guard active, !paused, chunks.indices.contains(chunkIndex) else { return }
        let utterance = AVSpeechUtterance(string: chunks[chunkIndex].text)
        let voiceID = UserDefaults.standard.string(forKey: "reader.speechVoice") ?? ""
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceID) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let rate = UserDefaults.standard.object(forKey: "reader.speechRate") as? Double ?? 0.5
        utterance.rate = Float(min(0.65, max(0.25, rate)))
        speaking = utterance; if !simulated { synthesizer.speak(utterance) }
    }
    func toggle() { if paused { resume() } else { pause() } }
    func pause() {
        guard active else { return }; paused = true
        synthesizer.pauseSpeaking(at: .immediate); updateNowPlaying()
    }
    func resume() {
        guard active else { return }; paused = false
        if simulated { if !loading && speaking == nil { speakChunk() }; updateNowPlaying(); return }
        if !simulated { try? AVAudioSession.sharedInstance().setActive(true) }
        if synthesizer.isPaused { synthesizer.continueSpeaking() }
        else if !loading && !synthesizer.isSpeaking { speakChunk() }
        updateNowPlaying()
    }
    func stop() {
        token = UUID(); loadTask?.cancel(); sleepTask?.cancel(); loadTask = nil; sleepTask = nil
        speaking = nil; synthesizer.stopSpeaking(at: .immediate)
        active = false; paused = false; loading = false; owner = ""; loader = nil; progress = nil; positionMap = nil; chunks = []
        if !simulated {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
    private func updateNowPlaying() {
        guard !simulated else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: chapterTitle,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue, MPNowPlayingInfoPropertyPlaybackRate: paused ? 0.0 : 1.0]
    }
    @objc private func interrupted(_ note: Notification) {
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        if type == .began { resumeAfterInterruption = active && !paused; pause() }
        else if type == .ended {
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if resumeAfterInterruption && options.contains(.shouldResume) { resume() }; resumeAfterInterruption = false
        }
    }
    @objc private func routeChanged(_ note: Notification) { if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() } }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard speaking === utterance, active else { return }
            if chunks.indices.contains(chunkIndex) { progress?(chapterIndex, chunks[chunkIndex].utf16Offset + (chunks[chunkIndex].text as NSString).length) }
            chunkIndex += 1
            if chunks.indices.contains(chunkIndex) { if !paused { speakChunk() } }
            else if UserDefaults.standard.bool(forKey: "reader.stopAfterChapter") { stop() }
            else { load(chapterIndex + 1, offset: 0) }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in guard speaking === utterance, active else { return }; stop(); message = "朗读被系统中止，可以从已保存的位置重新开始。" }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard speaking === utterance, chunks.indices.contains(chunkIndex), Date().timeIntervalSince(lastProgress) > 0.8 else { return }
            lastProgress = Date(); progress?(chapterIndex, chunks[chunkIndex].utf16Offset + range.location)
        }
    }
}

#if DEBUG
extension ReaderSpeech {
    @MainActor static func checkContinuousPlayback() async {
        let file = URL.documentsDirectory.appendingPathComponent("speech-check.json")
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "reader.stopAfterChapter"), minutes = defaults.object(forKey: "reader.sleepMinutes")
        defaults.set(false, forKey: "reader.stopAfterChapter"); defaults.set(0, forKey: "reader.sleepMinutes")
        defer {
            if let old { defaults.set(old, forKey: "reader.stopAfterChapter") } else { defaults.removeObject(forKey: "reader.stopAfterChapter") }
            if let minutes { defaults.set(minutes, forKey: "reader.sleepMinutes") } else { defaults.removeObject(forKey: "reader.sleepMinutes") }
        }
        let player = ReaderSpeech(simulated: true)
        var requested: [Int] = [], positions: [Int] = []
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<100 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            throw SourceError.message("听书状态转换超时")
        }
        do {
            player.start(owner: "test", title: "公版故事", chapter: 0, offset: 0, loader: { index in
                requested.append(index); return index < 2 ? ("第\(index + 1)章", "这是一段简短测试正文。") : nil
            }, progress: { index, _ in positions.append(index) })
            try await wait { player.speaking != nil }
            guard let first = player.speaking else { throw SourceError.message("首章未进入朗读队列") }
            player.pause(); guard player.paused else { throw SourceError.message("暂停状态错误") }; player.resume()
            player.speechSynthesizer(player.synthesizer, didFinish: first)
            try await wait { player.chapterIndex == 1 && player.speaking != nil }
            // Late callbacks from the previous utterance must not advance the new chapter.
            let second = player.speaking!
            player.speechSynthesizer(player.synthesizer, didFinish: first)
            try await Task.sleep(for: .milliseconds(20))
            guard player.speaking === second else { throw SourceError.message("过期回调改变了当前朗读") }
            player.speechSynthesizer(player.synthesizer, didFinish: second)
            try await wait { !player.active }
            guard requested == [0, 1, 2], positions.contains(0), positions.contains(1) else { throw SourceError.message("自动接章或进度保存错误") }
            let transformer = SpeechTextPresentation(rules: [TextReplacementRule(name: "净化", pattern: "广告", replacement: "")], conversion: "none")
            let original = "广告广告这里才是正文。"
            var mappedOffsets: [Int] = []
            player.start(owner: "transformed", title: "净化听书", chapter: 0, offset: 4, loader: { index in
                guard index == 0 else { return nil }
                return try await transformer.prepare(index: index, title: "第一章", text: original, book: "测试", origin: "local")
            }, positionMap: { transformer.offset(chapter: $0, value: $1, original: $2) }, progress: { _, offset in mappedOffsets.append(offset) })
            try await wait { player.speaking != nil }
            guard let transformed = player.speaking, transformed.speechString == "这里才是正文。", mappedOffsets.first == 4 else { throw SourceError.message("净化听书未使用转换后正文或原文起点映射错误") }
            player.speechSynthesizer(player.synthesizer, didFinish: transformed)
            try await wait { !player.active }
            guard mappedOffsets.last == (original as NSString).length else { throw SourceError.message("净化听书保存了错误的原文结束位置") }
            try Data(#"{"status":"passed","chapterAdvance":true,"pauseResume":true,"staleCallbackIgnored":true,"endOfBook":true,"transformedOffsets":true,"audioOutput":"not_tested"}"#.utf8).write(to: file, options: .atomic)
        } catch {
            player.stop()
            let data = try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription])
            try? data?.write(to: file, options: .atomic)
        }
    }
}
#endif

struct SpeechMiniPlayer: View {
    @ObservedObject private var player = ReaderSpeech.shared
    var body: some View {
        if player.active {
            HStack {
                Image(systemName: "headphones")
                Text(player.title).font(.subheadline).lineLimit(1)
                Spacer()
                if player.loading { ProgressView() }
                Button { player.toggle() } label: { Image(systemName: player.paused ? "play.fill" : "pause.fill") }.accessibilityLabel(player.paused ? "继续听书" : "暂停听书")
                Button { player.stop() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("停止听书")
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal).padding(.bottom, 58)
        }
    }
}
