//
//  ShareSheet.swift
//  OpenList iOS
//
//  UIActivityViewController 的 SwiftUI 封装。
//  用于把下载好的文件分享出去、或在其它 App 里打开
//  —— QuickLook 对 .ipa / .zip / .apk 这类没有渲染器，只会显示一个空白页。
//

import SwiftUI
import UIKit

struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
