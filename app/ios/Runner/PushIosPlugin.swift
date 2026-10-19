import Flutter
import UIKit
import UserNotifications

final class PushIosPlugin: NSObject, FlutterPlugin {
  private var pendingResult: FlutterResult?

  static func register(with registry: FlutterPluginRegistry) {
    let registrar = registry.registrar(forPlugin: "PushIosPlugin")!
    let instance = PushIosPlugin()
    let channel = FlutterMethodChannel(
      name: "tinyweb/push_ios",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler(instance.handle)
    registrar.addApplicationDelegate(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestToken":
      pendingResult = result
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) {
        granted, _ in
        guard granted else {
          result(nil)
          return
        }
        DispatchQueue.main.async {
          UIApplication.shared.registerForRemoteNotifications()
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    pendingResult?(token)
    pendingResult = nil
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    pendingResult?(nil)
    pendingResult = nil
  }
}
