//
//  PlayerScreen.swift
//  OpenList iOS
//
//  视频 / 音频播放。
//
//  关键点：AVPlayer 的 URL 不能带自定义请求头，所以必须用
//  AVURLAsset 的 AVURLAssetHTTPHeaderFieldsKey 传 Authorization，
//  否则所有需要鉴权的直链都会 403。
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
    @State private var duration: Double = 0
    @State private var position: Double = 0
    @State private var rate: Float = 1
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if loading {
                ProgressView("正在解析直链…")
                    .tint(.white)
                    .foregroundStyle(.white)
            } else if let errorText {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text(errorText)
                        .multilineTextAlignment(.center)
                        .font(.footnote)
                    Button("重试") { Task { await prepare() } }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(28)
            } else if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
                controls(player)
            }
        }
        .navigationTitle(title.isEmpty ? "播放" : title)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            rate = Float(value)
                            player?.rate = rate
                        } label: {
                            Label(String(format: "%.2fx", value),
                                  systemImage: abs(rate - Float(value)) < 0.01 ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "speedometer")
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            teardown()
            savePosition()
        }
        .task { await prepare() }
    }

    // MARK: - 控制层

    private func controls(_ player: AVPlayer) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 10) {
                Slider(value: Binding(
                    get: { position },
                    set: { newValue in
                        position = newValue
                        player.seek(to: CMTime(seconds: newValue, preferredTimescale: 600))
                    }
                ), in: 0...max(1, duration))
                .tint(.white)

                HStack(spacing: 26) {
                    Text(Fmt.duration(position)).monospacedDigit()
                    Spacer()
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 26))
                    }
                    Spacer()
                    Text(Fmt.duration(duration)).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 34)
            .background(
                LinearGradient(colors: [.clear, .black.opacity(0.6)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }

    private func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.rate = rate
        }
        isPlaying.toggle()
    }

    // MARK: - 准备

    private func prepare() async {
        loading = true
        errorText = nil
        do {
            let url: URL
            var headers: [String: String] = [:]
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
                if OlHttp.sameHost(server.url, link.url) { headers["Authorization"] = token }
            }

            let asset = AVURLAsset(url: url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": headers,
                "AVURLAssetOutOfBandMIMETypeKey": "application/octet-stream",
            ])
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true

            self.player = player
            self.loading = false

            // 读取时长（iOS 16 的 async load；失败不影响播放）
            if let cmDuration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(cmDuration)
                if seconds.isFinite && seconds > 0 { duration = seconds }
            }

            // 断点续播
            if let serverId {
                let saved = settings.playbackPosition(serverId: serverId, path: path)
                if saved > 3 { player.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
            }

            attachObservers(player)
            player.play()
            isPlaying = true
        } catch {
            errorText = (error as? ApiError)?.message ?? error.localizedDescription
            loading = false
        }
    }

    private func attachObservers(_ player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { time in
            position = time.seconds.isFinite ? time.seconds : 0
            if let item = player.currentItem, item.duration.seconds.isFinite, item.duration.seconds > 0 {
                duration = item.duration.seconds
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            isPlaying = false
            if let serverId = serverId {
                settings.savePlaybackPosition(serverId: serverId, path: path, seconds: 0)
            }
        }
    }

    private func savePosition() {
        guard let serverId, position > 3, duration <= 0 || position < duration - 5 else { return }
        settings.savePlaybackPosition(serverId: serverId, path: path, seconds: position)
    }

    private func teardown() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
    }
}

// MARK: - AVPlayerLayer 封装

struct VideoSurface: UIViewRepresentable {

    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
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
