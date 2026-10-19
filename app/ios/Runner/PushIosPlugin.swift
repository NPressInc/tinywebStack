import Flutter
import UIKit
import UserNotifications

final class PushIosPlugin: NSObject, FlutterPlugin {
  private var pendingResult: FlutterResult?

  private static var shared: PushIosPlugin?

  static func register(in registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "PushIosPlugin") else { return }
    register(with: registrar)
  }

  // FlutterPlugin conformance.
  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PushIosPlugin()
    shared = instance
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
          DispatchQueue.main.async {
            self.pendingResult = nil
            result(nil)
          }
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
