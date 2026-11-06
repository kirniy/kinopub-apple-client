//
//  Sidebar.swift
//  KinoPubAppleClient
//
//  Created by Kirill Kunst on 11.08.2023.
//

import Foundation
import SwiftUI
import KinoPubUI
import KinoPubBackend
import KinoPubKit

struct Sidebar: View {

  @Binding var selection: SidebarItem?
  var onSelect: () -> Void = {}

  @Environment(\.appContext) var appContext
  @EnvironmentObject var authState: AuthState
  @EnvironmentObject var errorHandler: ErrorHandler
  @EnvironmentObject var navigationState: NavigationState
  @EnvironmentObject var networkMonitor: NetworkMonitor
  @ObservedObject private var visibility = SectionVisibilityStore.shared

  @State private var showProfile = false

  var body: some View {
    // Custom selection binding so picking a section also pops its stack back to root (like a tab bar).
    // Goes through the normal `selection` binding, so List highlighting/behaviour is unaffected.
    List(selection: Binding(
      get: { selection },
      set: { newValue in
        selection = newValue
        if let newValue { navigationState.popToRoot(for: newValue) }
      }
    )) {
      Section("Library".localized) {
        row(.search)
        row(.new)
        ForEach(SidebarItem.libraryCategories, id: \.self) { type in
          if visibility.isVisible(.category(type)) { row(.category(type)) }
        }
        ForEach(CatalogPreset.visible) { preset in
          if visibility.isVisible(.preset(preset)) { row(.preset(preset)) }
        }
        if visibility.isVisible(.sport) { row(.sport) }
        row(.collections)
      }

      Section("Other".localized) {
        ForEach(SectionVisibilityStore.editableOther) { item in
          if visibility.isVisible(item) { row(item) }
        }
      }

      // Profile sits in its own section so it reads as separate from the library/other rows.
      Section {
        Button {
          showProfile = true
        } label: {
          Label("Profile".localized, systemImage: "person.crop.circle")
        }
#if os(macOS)
        .buttonStyle(.borderless)
#else
        .buttonStyle(.plain)
#endif
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(Color.KinoPub.background)
    .navigationTitle("KinoPub")
#if os(macOS)
    .navigationSplitViewColumnWidth(min: 220, ideal: 240)
#endif
    .sheet(isPresented: $showProfile) {
      profileSheet
    }
  }

  @ViewBuilder
  func row(_ item: SidebarItem) -> some View {
    let locked = !networkMonitor.isOnline && !item.isAvailableOffline
#if os(visionOS)
    Button {
      guard !locked else { return }
      selection = item
      navigationState.popToRoot(for: item)
      onSelect()
    } label: {
      rowLabel(item, locked: locked)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverEffect()
    .disabled(locked)
    .accessibilityAddTraits(selection == item ? .isSelected : [])
    .listRowBackground(selection == item ? Color.KinoPub.accent.opacity(0.18) : Color.clear)
#else
    rowLabel(item, locked: locked).tag(item)
#endif
  }

  private func rowLabel(_ item: SidebarItem, locked: Bool) -> some View {
    Label {
      HStack {
        Text(item.title.localized)
        if locked {
          Spacer(minLength: 6)
          Image(systemName: "lock.fill").font(.caption2)
        }
      }
    } icon: {
      Image(systemName: item.systemImage)
    }
    .foregroundStyle(locked ? Color.KinoPub.subtitle : Color.KinoPub.text)
  }

  private var profileSheet: some View {
    ProfileSheetContent(
      model: ProfileModel(userService: appContext.userService,
                          errorHandler: errorHandler,
                          authState: authState)
    )
    .environmentObject(authState)
    .environmentObject(errorHandler)
    .environmentObject(navigationState)
  }
}

private struct ProfileSheetContent: View {
  @Environment(\.dismiss) private var dismiss
  let model: ProfileModel

  init(model: @autoclosure @escaping () -> ProfileModel) {
    self.model = model()
  }

  var body: some View {
    ProfileView(model: model, onClose: { dismiss() })
  }
}

struct Sidebar_Previews: PreviewProvider {
  struct Preview: View {
    @State private var selection: SidebarItem? = .new
    var body: some View {
      Sidebar(selection: $selection)
        .environmentObject(AuthState(authService: AuthorizationServiceMock(),
                                     accessTokenService: AccessTokenServiceMock(),
                                     deviceService: DeviceServiceMock()))
        .environmentObject(ErrorHandler())
        .environmentObject(NavigationState())
    }
  }

  static var previews: some View {
    NavigationSplitView {
      Preview()
    } detail: {
      Text("Detail!")
    }
  }
}
