import AVFoundation
import AppKit
import CoreLocation
import Speech
import UserNotifications
import WebKit

/// What macOS lets Mote itself use, under each site permission: a site Mote
/// allows still gets nothing while macOS says no.
enum SystemAccess {
    /// Whether macOS keeps `kind` from Mote: turned off, or not allowed yet.
    static func withheld(_ kind: SitePermissions.Kind) async -> Bool {
        switch kind {
        case .capture(.camera): denied(AVCaptureDevice.authorizationStatus(for: .video))
        case .capture(.microphone): denied(AVCaptureDevice.authorizationStatus(for: .audio))
        case .capture: denied(AVCaptureDevice.authorizationStatus(for: .video)) || denied(AVCaptureDevice.authorizationStatus(for: .audio))
        case .notifications: await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
        case .location: [.denied, .restricted].contains(CLLocationManager().authorizationStatus)
        // Asked of macOS only when a site first shares: until then, not allowed.
        case .screen: !CGPreflightScreenCaptureAccess()
        case .speech: [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
        }
    }

    private static func denied(_ status: AVAuthorizationStatus) -> Bool { status == .denied || status == .restricted }

    /// Mote's place in System Settings for `kind`.
    static func open(_ kind: SitePermissions.Kind) {
        if kind == .notifications { return WebNotifications.openSystemSettings() }
        let pane: String =
            switch kind {
            case .capture(.microphone): "Privacy_Microphone"
            case .capture: "Privacy_Camera"
            case .location: "Privacy_LocationServices"
            case .screen: "Privacy_ScreenCapture"
            case .speech: "Privacy_SpeechRecognition"
            case .notifications: ""
            }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
