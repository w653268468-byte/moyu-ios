import SwiftUI
import AVFoundation
import MediaPlayer

@MainActor final class ReaderSpeech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
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
    private var originalProgress: ((Int, Int) -> Void)?
    private var spokenOffset = 0
    private var chunks: [SpeechTextChunk] = []
    private var chunkIndex = 0
    private var speaking: AVSpeechUtterance?
    private var lastProgress = Date.distantPast
    private var resumeAfterInterruption = false
    private var chapterTitle = ""
    private var observers: [NSObjectProtocol] = []
    private let simulated: Bool
    private var networkClient = NetworkSpeechClient()
    private var networkEngine: NetworkSpeechEngine?
    private var audioPlayer: AVAudioPlayer?
    private var audioTask: Task<Void, Never>?
    private var prefetchedAudio: (chapter: Int, chunk: Int, speed: Int, task: Task<Data, Error>)?
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
               loader: @escaping (Int) async throws -> (String, String)?, positionMap: ((Int, Int, Bool) -> Int)? = nil, progress: @escaping (Int, Int) -> Void, overrideEngine: NetworkSpeechEngine? = nil) {
        if active && self.owner == owner { toggle(); return }
        stop()
        message = nil; networkClient = NetworkSpeechClient()
        let selected = UserDefaults.standard.string(forKey: "reader.speechEngine") ?? ""
        networkEngine = overrideEngine ?? (simulated ? nil : NetworkVoiceStore.shared.engines.first { String($0.id) == selected })
        if !simulated && !selected.isEmpty && networkEngine == nil { message = "选中的网络音色已移除，请重新选择音色。"; return }
        do {
            if !simulated {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            }
        } catch { message = "无法开启听书音频：" + error.localizedDescription; return }
        self.owner = owner; self.title = title; self.loader = loader; self.positionMap = positionMap
        originalProgress = progress
        self.progress = { [weak self] chapter, offset in self?.spokenOffset = offset; progress(chapter, positionMap?(chapter, offset, true) ?? offset) }
        active = true; paused = false
        let minutes = min(180, max(0, UserDefaults.standard.integer(forKey: "reader.sleepMinutes")))
        if minutes > 0 { sleepTask = Task { try? await Task.sleep(for: .seconds(minutes * 60)); guard !Task.isCancelled else { return }; self.stop() } }
        load(chapter, offset: offset)
    }
    private func load(_ index: Int, offset: Int) {
        loadTask?.cancel(); token = UUID(); let current = token
        audioTask?.cancel(); prefetchedAudio?.task.cancel(); prefetchedAudio = nil; audioPlayer?.stop(); audioPlayer = nil
        speaking = nil; synthesizer.stopSpeaking(at: .immediate); loading = true
        guard let loader else { stop(); return }
        loadTask = Task {
            let background = UIApplication.shared.beginBackgroundTask(withName: "Gavin 听书章节") { [weak self] in Task { @MainActor in self?.stop() } }
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            do {
                guard let (name, text) = try await loader(index) else { if current == token { stop() }; return }
                try Task.checkCancellation(); guard current == token else { return }
                let value = SpeechText.chunks(text, startingAt: positionMap?(index, offset, false) ?? offset, maximumCharacters: networkEngine == nil ? 1200 : 320)
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
        if let engine = networkEngine { playNetworkChunk(engine); return }
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
        audioPlayer?.pause()
        synthesizer.pauseSpeaking(at: .immediate); updateNowPlaying()
    }
    func resume() {
        guard active else { return }; paused = false
        if networkEngine != nil {
            if !simulated { try? AVAudioSession.sharedInstance().setActive(true); audioPlayer?.play() }
            if !loading && audioPlayer == nil { speakChunk() }; updateNowPlaying(); return
        }
        if simulated { if !loading && speaking == nil { speakChunk() }; updateNowPlaying(); return }
        if !simulated { try? AVAudioSession.sharedInstance().setActive(true) }
        if synthesizer.isPaused { synthesizer.continueSpeaking() }
        else if !loading && !synthesizer.isSpeaking { speakChunk() }
        updateNowPlaying()
    }
    func stop() {
        token = UUID(); loadTask?.cancel(); sleepTask?.cancel(); loadTask = nil; sleepTask = nil
        speaking = nil; synthesizer.stopSpeaking(at: .immediate)
        audioTask?.cancel(); audioTask = nil; prefetchedAudio?.task.cancel(); prefetchedAudio = nil
        audioPlayer?.stop(); audioPlayer = nil; networkEngine = nil
        active = false; paused = false; loading = false; owner = ""; loader = nil; progress = nil; originalProgress = nil; positionMap = nil; chunks = []
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
            advanceChunk()
        }
    }

    func preview(_ engine: NetworkSpeechEngine) {
        start(owner: "voice-preview:\(engine.id)", title: engine.name, chapter: 0, offset: 0,
              loader: { index in index == 0 ? (engine.name, "你好，这是 Gavin 在线朗读试听。愿每一段故事，都有喜欢的声音陪伴。") : nil }, progress: { _, _ in }, overrideEngine: engine)
    }
    func changeVoice(_ engine: NetworkSpeechEngine?) {
        UserDefaults.standard.set(engine.map { String($0.id) } ?? "", forKey: "reader.speechEngine")
        guard active, let loader, let progress = originalProgress else { return }
        let oldOwner = owner, oldTitle = title, chapter = chapterIndex, mapping = positionMap, wasPaused = paused
        let offset = mapping?(chapter, spokenOffset, true) ?? spokenOffset
        stop()
        start(owner: oldOwner, title: oldTitle, chapter: chapter, offset: offset, loader: loader, positionMap: mapping, progress: progress, overrideEngine: engine)
        if wasPaused { pause() }
    }
    private func playNetworkChunk(_ engine: NetworkSpeechEngine) {
        audioTask?.cancel()
        let current = token, chapter = chapterIndex, chunk = chunkIndex
        let speed = min(50, max(5, UserDefaults.standard.object(forKey: "reader.networkSpeechSpeed") as? Int ?? 10))
        let prepared = prefetchedAudio; prefetchedAudio = nil
        loading = true
        audioTask = Task {
            do {
                if chunk > 0, engine.pauseDuration > 0 { try await Task.sleep(for: .milliseconds(engine.pauseDuration)) }
                let data: Data
                if let prepared, prepared.chapter == chapter, prepared.chunk == chunk, prepared.speed == speed {
                    do { data = try await prepared.task.value }
                    catch { try Task.checkCancellation(); data = try await networkClient.render(engine, text: chunks[chunk].text, speed: speed) }
                } else {
                    prepared?.task.cancel()
                    data = try await networkClient.render(engine, text: chunks[chunk].text, speed: speed)
                }
                try Task.checkCancellation(); guard active, token == current, chapterIndex == chapter, chunkIndex == chunk else { return }
                let player = try AVAudioPlayer(data: data)
                guard player.duration.isFinite, player.duration > 0, simulated || player.prepareToPlay() else { throw SourceError.message("返回音频无法解码或为空。") }
                player.delegate = self; audioPlayer = player; loading = false
                progress?(chapter, chunks[chunk].utf16Offset)
                if !paused && !simulated, !player.play() { throw SourceError.message("无法播放在线音频，请检查音频输出。") }
                if chunks.indices.contains(chunk + 1) {
                    let next = chunks[chunk + 1].text, client = networkClient
                    prefetchedAudio = (chapter, chunk + 1, speed, Task { try await client.render(engine, text: next, speed: speed) })
                }
                updateNowPlaying()
            } catch {
                guard token == current, !Task.isCancelled else { return }
                stop(); message = "在线朗读失败：" + error.localizedDescription
            }
        }
    }
    private func advanceChunk() {
        if chunks.indices.contains(chunkIndex) { progress?(chapterIndex, chunks[chunkIndex].utf16Offset + (chunks[chunkIndex].text as NSString).length) }
        chunkIndex += 1
        if chunks.indices.contains(chunkIndex) { if !paused { speakChunk() } }
        else if UserDefaults.standard.bool(forKey: "reader.stopAfterChapter") { stop() }
        else { load(chapterIndex + 1, offset: 0) }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard audioPlayer === player, active else { return }
            audioPlayer = nil
            guard flag else { stop(); message = "在线音频播放中断，请重试。"; return }
            advanceChunk()
        }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in guard audioPlayer === player, active else { return }; stop(); message = "在线音频解码失败，请更换音色或重试。" }
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
            for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
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
            let engine = NetworkSpeechEngine(id: 990, name: "原生网络音频检查", url: "http://127.0.0.1:18765/tts-audio?text={{java.encodeURI(speakText)}}&speed={{speakSpeed}}")
            let network = ReaderSpeech(simulated: true)
            var networkRequests: [Int] = [], networkPositions: [Int] = []
            network.start(owner: "network-test", title: "网络朗读", chapter: 0, offset: 0, loader: { index in
                networkRequests.append(index)
                if index == 0 { return ("第一章", String(repeating: "网络音频解码与下一段预取。", count: 40)) }
                return index == 1 ? ("第二章", "自动接续下一章。") : nil
            }, progress: { chapter, _ in networkPositions.append(chapter) }, overrideEngine: engine)
            try await wait { network.audioPlayer != nil }
            guard let audio = network.audioPlayer, audio.duration > 0 else { throw SourceError.message("网络 WAV 未完成原生解码") }
            network.pause(); guard network.paused else { throw SourceError.message("网络朗读暂停失败") }; network.resume()
            network.audioPlayerDidFinishPlaying(audio, successfully: true)
            try await wait { network.audioPlayer != nil && network.chunkIndex == 1 }
            let nextAudio = network.audioPlayer!
            network.audioPlayerDidFinishPlaying(audio, successfully: true)
            try await Task.sleep(for: .milliseconds(20))
            guard network.audioPlayer === nextAudio else { throw SourceError.message("旧网络音频回调改变了播放位置") }
            network.audioPlayerDidFinishPlaying(nextAudio, successfully: true)
            try await wait { network.chapterIndex == 1 && network.audioPlayer != nil }
            network.audioPlayerDidFinishPlaying(network.audioPlayer!, successfully: true)
            try await wait { !network.active }
            guard networkRequests == [0, 1, 2], networkPositions.contains(1) else { throw SourceError.message("网络音色未自动跨章或保存进度") }
            try Data(#"{"status":"passed","networkAudioDecodeAndAdvance":true,"chapterAdvance":true,"pauseResume":true,"staleCallbackIgnored":true,"endOfBook":true,"transformedOffsets":true,"audioOutput":"not_tested"}"#.utf8).write(to: file, options: .atomic)
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
    @State private var voices = false
    var body: some View {
        if player.active {
            HStack {
                Image(systemName: "headphones")
                Text(player.title).font(.subheadline).lineLimit(1)
                Spacer()
                Button { voices = true } label: { Image(systemName: "waveform") }.accessibilityLabel("切换朗读音色")
                if player.loading { ProgressView() }
                Button { player.toggle() } label: { Image(systemName: player.paused ? "play.fill" : "pause.fill") }.accessibilityLabel(player.paused ? "继续听书" : "暂停听书")
                Button { player.stop() } label: { Image(systemName: "stop.fill") }.accessibilityLabel("停止听书")
            }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(.horizontal).padding(.bottom, 58)
                .sheet(isPresented: $voices) { NavigationStack { NetworkVoicesView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { voices = false } } } } }
        }
    }
}
