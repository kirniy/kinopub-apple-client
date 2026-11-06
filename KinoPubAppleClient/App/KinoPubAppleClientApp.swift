//
//  KinoPubAppleClientApp.swift
//  KinoPubAppleClient
//
//  Created by Kirill Kunst on 17.07.2023.
//

import SwiftUI
import KinoPubKit

enum WindowSize {
  static let macos = CGSize(width: 1280, height: 720)
}

@main
struct KinoPubAppleClientApp: App {
  
  @StateObject var navigationState = NavigationState()
  @StateObject var errorHandler = ErrorHandler()
  @StateObject var authState = AuthState(authService: AppContext.shared.authService,
                                         accessTokenService: AppContext.shared.accessTokenService,
                                         deviceService: AppContext.shared.deviceService)
  @StateObject var networkMonitor = NetworkMonitor()
#if os(visionOS)
  @StateObject private var floatingPlayback = VisionFloatingPlayback()
  @StateObject private var stereoFullscreen = VisionStereoFullscreen()
#endif

#if os(macOS)
  @StateObject var windowSettings = WindowSettings()
#endif
  
#if os(iOS)
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
#endif
  
#if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
#endif
  
  var body: some Scene {
    WindowGroup {
      RootView()
        // The app is dark-only; the color assets' "Any" (light) appearance is authored inconsistently
        // (dark background but black text), so on a Light-mode Mac text/icons render invisible. Force
        // dark so the assets always resolve their Dark variant.
        .preferredColorScheme(.dark)
        .environment(\.appContext, AppContext.shared)
        .environmentObject(navigationState)
        .environmentObject(authState)
        .environmentObject(errorHandler)
        .environmentObject(networkMonitor)
        .environmentObject(AppContext.shared.libraryState)
#if os(visionOS)
        .environmentObject(floatingPlayback)
        .environmentObject(stereoFullscreen)
#endif
        // Register this device's name once authorized, so it isn't listed as "unknown".
        .task(id: authState.userState) {
          if authState.userState == .authorized {
            await AppContext.shared.deviceService.registerDeviceName()
            // Advertise HEVC/4K so kino.pub serves HEVC + HDR10 streams to the native player.
            await AppContext.shared.deviceService.syncCapabilities()
          }
        }
        // Ask once for permission to post download-complete notifications.
        .task {
          await AppContext.shared.downloadNotificationManager.requestPermission()
        }
#if os(macOS)
        .frame(minWidth: WindowSize.macos.width, minHeight: WindowSize.macos.height)
#endif
    }
#if os(macOS)
    .windowResizability(.contentSize)
#elseif os(visionOS)
    .defaultSize(width: 1200, height: 800)
    .immersiveEnvironmentBehavior(.coexist)
#endif

#if os(visionOS)
    WindowGroup("KinoPub Video", id: VisionFloatingPlayback.windowID, for: String.self) { _ in
      VisionFloatingPlayer()
        .environmentObject(floatingPlayback)
        .environmentObject(stereoFullscreen)
    }
    .defaultSize(width: 560, height: 350)
    .immersiveEnvironmentBehavior(.coexist)

    WindowGroup("KinoPub 3D", id: VisionStereoFullscreen.windowID, for: String.self) { _ in
      if let manager = stereoFullscreen.manager {
        VisionStereoLargeWindow(manager: manager)
          .environmentObject(stereoFullscreen)
      }
    }
    .windowStyle(.plain)
    .defaultSize(width: 1800, height: 1100)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
    .immersiveEnvironmentBehavior(.coexist)
#endif
    
#if os(macOS)
    Settings {
      SettingsView()
        .environmentObject(windowSettings)
        .preferredColorScheme(.dark)
    }
#endif
  }
}
