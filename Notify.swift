// Notify.swift — 批量任务完成提醒：提示音 + macOS 系统通知
// 只被 GUI（App.swift）编译；CLI 与单测不引用本文件。
import AppKit
import UserNotifications

enum JobNotify {
    /// 任务正常完成时调用：按偏好播提示音、发系统通知（首次使用默认开）
    static func fire(_ title: String, _ body: String) {
        let d = UserDefaults.standard
        if d.object(forKey: "fxt_doneSound") == nil || d.bool(forKey: "fxt_doneSound") {
            playSound()
        }
        if d.object(forKey: "fxt_doneNotify") == nil || d.bool(forKey: "fxt_doneNotify") {
            postNotification(title: title, body: body)
        }
    }

    static func playSound() {
        // Glass：系统自带，清脆不刺耳；找不到就退回哔声
        if NSSound(named: "Glass") == nil { NSSound.beep() } else { NSSound(named: "Glass")?.play() }
    }

    /// App 启动时预请求通知授权，避免第一次任务完成时才弹授权窗打断
    static func warmUp() {
        let d = UserDefaults.standard
        if d.object(forKey: "fxt_doneNotify") != nil && !d.bool(forKey: "fxt_doneNotify") { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            guard s.authorizationStatus == .notDetermined else { return }
            _ = center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private static func postNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                add(center, title: title, body: body)
            case .notDetermined:
                // 授权还没批：这批先靠提示音，弹一次授权请求，下次起就能收通知
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { add(center, title: title, body: body) }
                }
            default:
                break // 用户关掉了通知权限：静默跳过，提示音仍在
            }
        }
    }

    private static func add(_ center: UNUserNotificationCenter, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}
