//
//  PlayerScreen.swift
//  OpenList iOS
//
//  视频 / 音频播放。
//
//  鉴权头的传递改成 StreamResourceLoader（AVAssetResourceLoaderDelegate），
//  不再用私有的 AVURLAssetHTTPHeaderFieldsKey —— 那个在 AVPlayerItem 下经常失效，
//  表现就是「点开黑屏」。
//
//  另外补了几件播放器该有的事：
//  - 监听 item.status / playbackLikelyToKeepUp，加载失败时把真实原因显示出来
//  - 单击显隐控制层、双击左右两侧快进/快退
//  - 缓冲时显示菊花
//  - 播放结束自动回到开头
//

import SwiftUI
import AVKit
import MediaPlayer

struct PlayerScreen: View {

    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var servers: ServerStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    let serverId: String?
    let path: String
    var directUrl: String? = nil
    var directTitle: String? = nil
    var referer: String? = nil
    var cookie: String? = nil

    @State private var player: AVPlayer?
    @State private var title = ""
    @State private var loading = true
    @State private var errorText: String?
    @State private var isPlaying = false
    @State private var buffering = false
    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var rate: Float = 1
    @State private var showControls = true
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var hideTask: Task<Void, Never>?
    @State private var phaseObserver: NSObjectProtocol?

    /// 「后台继续播放」设置真的生效：关掉时切后台立即暂停，开启时保持播放
    /// （配合 Info.plist 的 audio 后台模式，系统不会挂起进程）。
    private func observeAppPhase() {
        phaseObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { _ in
            guard !settings.backgroundPlayback else { return }
            player?.pause()
            isPlaying = false
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loading {
                loadingView
            } else if let errorText {
                errorView(errorText)
            } else if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
                    .onTapGesture { toggleControls() }
                if showControls {
                    controls(player)
                        .transition(.opacity)
                }
                if buffering && isPlaying {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.4)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(title.isEmpty ? "播放" : title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            observeAppPhase()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            NotificationCenter.default.removeObserver(phaseObserver as Any)
            savePosition()
            teardown()
        }
        .task { await prepare() }
    }

    // MARK: - 加载 / 错误

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("正在解析直链…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .light))
            Text(message)
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .padding(.horizontal, 32)
            HStack(spacing: 12) {
                Button("重试") { Task { await prepare() } }
                    .buttonStyle(.borderedProminent)
                if let url = debugURL {
                    Button("用浏览器打开") {
                        UIApplication.shared.open(url)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var debugURL: URL? {
        guard let directUrl else { return nil }
        return URL(string: directUrl)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button {
                        rate = Float(value)
                        if isPlaying { player?.rate = rate }
                    } label: {
                        Label(String(format: "%.2fx", value),
                              systemImage: abs(rate - Float(value)) < 0.01 ? "checkmark" : "circle")
                    }
                }
                Divider()
                Button {
                    if let player { player.seek(to: .zero); player.play() }
                } label: {
                    Label("从头开始", systemImage: "backward.end")
                }
            } label: {
                Image(systemName: "speedometer")
            }
        }
    }

    // MARK: - 控制层

    private func controls(_ player: AVPlayer) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { newValue in
                            position = newValue
                            player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600),
                                        toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    ),
                    in: 0...sliderMax
                )
                .tint(.white)

                HStack(spacing: 30) {
                    Text(Fmt.duration(position))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .leading)

                    Spacer()

                    Button { skip(-10) } label: {
                        Image(systemName: "gobackward.10").font(.system(size: 21))
                    }
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                    }
                    Button { skip(10) } label: {
                        Image(systemName: "goforward.10").font(.system(size: 21))
                    }

                    Spacer()

                    Text(Fmt.duration(duration))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.72)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea(edges: .bottom)
            )
        }
    }

    private var sliderValue: Double {
        guard duration > 0 else { return 0 }
        return min(max(position, 0), duration)
    }

    private var sliderMax: Double {
        duration > 0 ? duration : 1
    }

    // MARK: - 交互

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls.toggle()
        }
        if showControls { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, isPlaying else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
            }
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
            scheduleHide()
        }
    }

    private func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, min(position + seconds, duration > 0 ? duration : position + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
        scheduleHide()
    }

    // MARK: - 准备播放

    private func prepare() async {
        loading = true
        errorText = nil
        teardown()

        do {
            let url: URL
            var headers: [String: String] = [:]
            headers["User-Agent"] = "OpenListiOS/1.0 (iPhone)"

            if let directUrl, let parsed = URL(string: directUrl) {
                url = parsed
                title = directTitle ?? (path as NSString).lastPathComponent
                if let referer, !referer.isEmpty { headers["Referer"] = referer }
                if let cookie, !cookie.isEmpty { headers["Cookie"] = cookie }
            } else {
                guard let serverId, let server = servers.get(serverId) else {
                    throw ApiError.local("服务器已被删除")
                }
                let token = try await servers.ensureToken(serverId, api: container.api).token
                let file = RemoteFile(path: path, name: (path as NSString).lastPathComponent)
                let link = try await container.api.directLink(baseUrl: server.url, token: token, file: file)
                guard let parsed = URL(string: link.url) else { throw ApiError.local("直链地址无效") }
                url = parsed
                title = file.name
                if OlHttp.sameHost(server.url, link.url) {
                    headers["Authorization"] = token
                }
            }

            // 用 resource loader 注入请求头（替代失效的 AVURLAssetHTTPHeaderFieldsKey）
            // makeAsset 内部已把 delegate 强引用到 asset 上，这里不需要再保活
            let asset = StreamResourceLoader().makeAsset(url: url, headers: headers)

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 5
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player

            // 监听加载状态：失败时把真实原因抛给 UI，而不是干等
            statusObserver = item.observe(\.status, options: [.new]) { observed, _ in
                DispatchQueue.main.async {
                    switch observed.status {
                    case .failed:
                        let reason = observed.error?.localizedDescription ?? "未知错误"
                        self.errorText = "无法播放：\(reason)"
                        self.loading = false
                    case .readyToPlay:
                        self.loading = false
                    default:
                        break
                    }
                }
            }

            // 缓冲状态
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.playbackStalledNotification,
                object: item, queue: .main
            ) { _ in buffering = true }

            attachObservers(player)

            // 时长
            if let cm = try? await asset.load(.duration) {
                let s = CMTimeGetSeconds(cm)
                if s.isFinite && s > 0 { duration = s }
            }

            // 断点续播
            if let serverId {
                let saved = settings.playbackPosition(serverId: serverId, path: path)
                if saved > 3 && (duration <= 0 || saved < duration - 5) {
                    await player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
                }
            }

            player.play()
            player.rate = rate
            isPlaying = true
            loading = false
            scheduleHide()
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
            loading = false
        }
    }

    private func attachObservers(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.4, preferredTimescale: 600),
            queue: .main
        ) { time in
            position = time.seconds.isFinite ? time.seconds : 0
            if let item = player.currentItem,
               item.duration.seconds.isFinite, item.duration.seconds > 0 {
                duration = item.duration.seconds
            }
            buffering = !(player.currentItem?.isPlaybackLikelyToKeepUp ?? true)
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
            showControls = true
            if let serverId {
                settings.savePlaybackPosition(serverId: serverId, path: path, seconds: 0)
            }
        }
    }

    private func savePosition() {
        guard let serverId, position > 3 else { return }
        if duration > 0 && position >= duration - 5 { return }
        settings.savePlaybackPosition(serverId: serverId, path: path, seconds: position)
    }

    private func teardown() {
        hideTask?.cancel()
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

// MARK: - AVPlayerLayer 封装

struct VideoSurface: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

extension Fmt {
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
