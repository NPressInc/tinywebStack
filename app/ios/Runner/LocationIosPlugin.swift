import CoreLocation
import Flutter

final class LocationIosPlugin: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
  private let manager = CLLocationManager()
  private var eventSink: FlutterEventSink?
  private var monitoring = false
  private let regionRadius: CLLocationDistance = 150
  private let regionId = "tinyweb_last_fix"

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    manager.pausesLocationUpdatesAutomatically = true
    manager.activityType = .other
    manager.allowsBackgroundLocationUpdates = true
    manager.showsBackgroundLocationIndicator = true
  }

  static func register(with registry: FlutterPluginRegistry) {
    let registrar = registry.registrar(forPlugin: "LocationIosPlugin")!
    let instance = LocationIosPlugin()
    let method = FlutterMethodChannel(
      name: "tinyweb/location_ios",
      binaryMessenger: registrar.messenger()
    )
    method.setMethodCallHandler { call, result in
      switch call.method {
      case "start":
        instance.start()
        result(nil)
      case "stop":
        instance.stop()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    let events = FlutterEventChannel(
      name: "tinyweb/location_ios/events",
      binaryMessenger: registrar.messenger()
    )
    events.setStreamHandler(instance)
  }

  func start() {
    guard !monitoring else { return }
    monitoring = true
    manager.startMonitoringSignificantLocationChanges()
    manager.requestLocation()
  }

  func stop() {
    monitoring = false
    manager.stopMonitoringSignificantLocationChanges()
    for region in manager.monitoredRegions where region.identifier == regionId {
      manager.stopMonitoring(for: region)
    }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    emit(location)
    armRegion(around: location)
  }

  func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
    manager.requestLocation()
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // Significant-change / one-shot fixes can fail when denied; Flutter handles permission UX.
  }

  private func armRegion(around location: CLLocation) {
    for region in manager.monitoredRegions where region.identifier == regionId {
      manager.stopMonitoring(for: region)
    }
    let region = CLCircularRegion(
      center: location.coordinate,
      radius: regionRadius,
      identifier: regionId
    )
    region.notifyOnEntry = false
    region.notifyOnExit = true
    manager.startMonitoring(for: region)
  }

  private func emit(_ location: CLLocation) {
    eventSink?([
      "lat": location.coordinate.latitude,
      "lon": location.coordinate.longitude,
      "acc": location.horizontalAccuracy,
      "alt": location.altitude,
      "vel": location.speed >= 0 ? location.speed : 0,
      "cog": location.course >= 0 ? location.course : 0,
      "tst": Int(location.timestamp.timeIntervalSince1970),
    ])
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
