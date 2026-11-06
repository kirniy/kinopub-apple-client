//
//  SidebarView.swift
//  KinoPubAppleClient
//
//  Created by Kirill Kunst on 11.08.2023.
//

import Foundation
import SwiftUI
import KinoPubUI
import KinoPubBackend
import KinoPubKit

struct SidebarView: View {

  @Environment(\.appContext) var appContext
  @EnvironmentObject var navigationState: NavigationState
  @EnvironmentObject var errorHandler: ErrorHandler
  @EnvironmentObject var authState: AuthState
  @EnvironmentObject var networkMonitor: NetworkMonitor

  @State private var sectionBeforeOffline: SidebarItem?
  @State private var showReconnected = false
#if os(visionOS)
  @EnvironmentObject private var floatingPlayback: VisionFloatingPlayback
  @AppStorage(VisionCatalogMultiview.preferenceKey) private var catalogMultiviewEnabled = false
  @StateObject private var catalogMultiview = VisionCatalogMultiview()
  @State private var showsCatalogMultiview = false
  @State private var startCatalogMultiview = false
  @AppStorage("visionSpatialLibraryVisible") private var isSidebarVisible = true
  @ScaledMetric(relativeTo: .body) private var railWidth: CGFloat = 250
#endif

  var body: some View {
#if os(macOS)
    // Show auth as full-window content (not a modal sheet): a macOS sheet disables the window's
    // close button, trapping the user on the activation screen with no way to quit the app.
    if authState.shouldShowAuthentication {
      authSheet
    } else {
      mainContent
    }
#else
    mainContent
      .sheet(isPresented: $authState.shouldShowAuthentication) { authSheet }
#endif
  }

  private var mainContent: some View {
    splitView
      .accentColor(Color.KinoPub.accent)
#if os(visionOS)
      .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
        HStack(spacing: 8) {
          Button {
            withAnimation { isSidebarVisible.toggle() }
          } label: {
            Label("Library".localized, systemImage: "sidebar.left")
          }
          .accessibilityValue(isSidebarVisible ? Text("Shown") : Text("Hidden"))
          .help(isSidebarVisible ? "Hide Library" : "Show Library")
          libraryShortcut(.history)
          libraryShortcut(.bookmarks)
          if catalogMultiviewEnabled {
            Button { showsCatalogMultiview = true } label: {
              Label("Multiview (\(catalogMultiview.items.count))", systemImage: "rectangle.split.2x2")
            }
          }
        }
        .padding(8)
        .glassBackgroundEffect(in: Capsule())
      }
      .environmentObject(catalogMultiview)
      .sheet(isPresented: $showsCatalogMultiview, onDismiss: startQueuedMultiview) {
        VisionCatalogMultiviewSheet(queue: catalogMultiview, session: catalogMultiview.session) {
          startCatalogMultiview = true
          showsCatalogMultiview = false
        }
      }
      .onChange(of: catalogMultiviewEnabled) { _, enabled in
        if !enabled { catalogMultiview.reset() }
      }
      .onChange(of: authState.userState) { _, state in
        if state != .authorized { catalogMultiview.reset() }
      }
#endif
    .animation(.easeInOut(duration: 0.25), value: networkMonitor.isOnline)
    .animation(.easeInOut(duration: 0.25), value: showReconnected)
    .onChange(of: networkMonitor.isOnline) { online in
      handleConnectivityChange(online: online)
    }
    .onChange(of: navigationState.sidebarSelection) { selection in
      // Bounce a tap on a locked (network-only) row back to Downloads while offline.
      if !networkMonitor.isOnline, let selection, !selection.isAvailableOffline {
        navigationState.sidebarSelection = .downloads
      }
    }
    // Tapping a download notification selects the Downloads section.
    .onReceive(NotificationCenter.default.publisher(for: .openDownloads)) { _ in
      navigationState.sidebarSelection = .downloads
    }
    .environmentObject(navigationState)
    .environmentObject(errorHandler)
    .task {
      await authState.check()
    }
  }

#if os(visionOS)
  private func startQueuedMultiview() {
    guard startCatalogMultiview, catalogMultiviewEnabled else {
      startCatalogMultiview = false
      return
    }
    startCatalogMultiview = false
    let items = catalogMultiview.items
    floatingPlayback.manager?.player.pause()
    Task { await catalogMultiview.session.start(items, available: items, catalog: appContext) }
  }

  private func libraryShortcut(_ item: SidebarItem) -> some View {
    Button {
      navigationState.sidebarSelection = item
      navigationState.popToRoot(for: item)
    } label: {
      Label(item.title.localized, systemImage: item.systemImage)
    }
    .disabled(!networkMonitor.isOnline && !item.isAvailableOffline)
  }
#endif

  @ViewBuilder
  private var splitView: some View {
#if os(visionOS)
    GeometryReader { geometry in
      splitDetail
        .ornament(visibility: isSidebarVisible ? .visible : .hidden,
                  attachmentAnchor: .scene(.leading), contentAlignment: .trailing) {
          VStack(alignment: .leading, spacing: 0) {
            HStack {
              Text("KinoPub").font(.headline)
              Spacer()
              Button {
                withAnimation { isSidebarVisible = false }
              } label: {
                Label("Hide Library", systemImage: "sidebar.leading")
                  .labelStyle(.iconOnly)
              }
              .buttonStyle(.borderless)
                .help("Hide Library")
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            Sidebar(selection: $navigationState.sidebarSelection)
          }
          .frame(width: min(railWidth, 340), height: min(max(geometry.size.height - 40, 280), 720))
          .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
          .padding(.trailing, 14)
        }
    }
#else
    NavigationSplitView(columnVisibility: $navigationState.columnVisibility) {
      Sidebar(selection: $navigationState.sidebarSelection)
    } detail: {
      splitDetail
    }
#endif
  }

  private var splitDetail: some View {
    SidebarNavigationDetail(selection: $navigationState.sidebarSelection)
      .safeAreaInset(edge: .top, spacing: 0) {
        if let banner = bannerState {
          OfflineBanner(tone: banner.tone, title: banner.title)
        }
      }
  }

  // MARK: - Offline mode

  private var bannerState: (tone: OfflineBanner.Tone, title: String)? {
    if !networkMonitor.isOnline {
      return (.warning, "You're offline — your downloads are available".localized)
    }
    if showReconnected {
      return (.success, "Back online".localized)
    }
    return nil
  }

  private func handleConnectivityChange(online: Bool) {
    if !online {
      let current = navigationState.sidebarSelection ?? .new
      if !current.isAvailableOffline { sectionBeforeOffline = current }
      navigationState.sidebarSelection = .downloads
    } else {
      showReconnected = true
      if navigationState.downloadsRoutes.isEmpty, let previous = sectionBeforeOffline {
        navigationState.sidebarSelection = previous
      }
      sectionBeforeOffline = nil
      Task {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        showReconnected = false
      }
    }
  }

  var authSheet: some View {
    AuthView(model: AuthModel(authService: appContext.authService,
                              authState: authState,
                              errorHandler: errorHandler))
  }

}

struct SideBarView_Previews: PreviewProvider {
  static var previews: some View {
    SidebarView()
  }
}

#if os(visionOS)
@MainActor
final class VisionCatalogMultiview: ObservableObject {
  static let preferenceKey = "visionCatalogMultiviewEnabled"
  @Published private(set) var items: [VisionMultiviewItem] = []
  let session = VisionMultiviewSession()

  func contains(_ id: Int) -> Bool { items.contains { $0.id == id } }

  func toggle(_ item: VisionMultiviewItem) {
    guard !session.isChanging else { return }
    if contains(item.id) {
      items.removeAll { $0.id == item.id }
      if session.activeIDs.contains(item.id) { Task { await session.toggle(item) } }
    } else if items.count < VisionMultiviewSession.limit {
      items.append(item)
      if !session.activeIDs.isEmpty && !session.activeIDs.contains(item.id) {
        Task { await session.toggle(item) }
      }
    }
  }

  func reset() {
    session.stop()
    items.removeAll()
  }
}

private struct VisionCatalogMultiviewSheet: View {
  @ObservedObject var queue: VisionCatalogMultiview
  @ObservedObject var session: VisionMultiviewSession
  let start: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        if queue.items.isEmpty {
          ContentUnavailableView("No Videos Added", systemImage: "rectangle.split.2x2",
            description: Text("Add movies from their detail pages or episodes from their menus."))
        }
        ForEach(queue.items) { item in
          HStack {
            Text(item.title)
            Spacer()
            Button("Remove", systemImage: "minus.circle") { queue.toggle(item) }
              .disabled(session.isChanging || !session.activeIDs.isEmpty)
          }
        }
        if let reason = session.errorMessage { Text(reason).font(.footnote) }
      }
      .navigationTitle("Multiview")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        ToolbarItem(placement: .confirmationAction) {
          if session.activeIDs.isEmpty {
            Button("Start Multiview", action: start).disabled(queue.items.count < 2 || session.isChanging)
          } else {
            Button("Close Multiview") { session.stop() }
          }
        }
      }
    }
    .presentationSizing(.form)
  }
}
#endif
