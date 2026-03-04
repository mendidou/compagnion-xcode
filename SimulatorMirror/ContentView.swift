import SwiftUI

struct ContentView: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedTab   = 0
    @State private var showDiscovery = false
    @State private var showTabBar    = true

    // ── Toggle button ─────────────────────────────────────────────────────────
    @State private var togglePos: CGPoint         = .zero
    @State private var togglePosSet               = false
    @State private var toggleDragOrigin: CGPoint? = nil

    // ── 3-dots button ─────────────────────────────────────────────────────────
    @State private var dotsPos: CGPoint           = .zero
    @State private var dotsPosSet                 = false
    @State private var dotsDragOrigin: CGPoint?   = nil

    var body: some View {
        ZStack(alignment: .bottom) {

            // ── Content ───────────────────────────────────────────────────────
            Group {
                switch selectedTab {
                case 0:
                    SimulatorTabView()
                case 1:
                    SessionTabView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: showTabBar ? 72 : 0)
                                .animation(nil, value: showTabBar)
                        }
                case 2:
                    BuildTabView()
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: showTabBar ? 72 : 0)
                                .animation(nil, value: showTabBar)
                        }
                default:
                    SettingsTabView(showDiscovery: $showDiscovery)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            Color.clear.frame(height: showTabBar ? 72 : 0)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(edges: .bottom)
            .animation(selectedTab == 1 ? nil : .spring(duration: 0.35), value: showTabBar)

            // ── Tab bar ───────────────────────────────────────────────────────
            if showTabBar {
                FloatingTabBar(selectedTab: $selectedTab)
                    .padding(.leading, 86)
                    .padding(.trailing, 20)
                    .padding(.bottom, 10)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal:   .move(edge: .bottom).combined(with: .opacity)
                    ))
            }
        }
        .ignoresSafeArea(edges: .bottom)

        // ── Floating buttons in a separate overlay so they never affect layout ─
        .overlay {
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        if !togglePosSet {
                            togglePos = CGPoint(x: 49,
                                               y: geo.size.height - 10 - 29 - 16)
                            togglePosSet = true
                        }
                        if !dotsPosSet {
                            dotsPos = CGPoint(x: geo.size.width - 16 - 29,
                                             y: geo.size.height * 0.15)
                            dotsPosSet = true
                        }
                    }

                if togglePosSet {
                    toggleButton
                        .gesture(toggleGesture)
                        .position(togglePos)
                }

                if dotsPosSet, selectedTab == 0 {
                    FloatingActionsButton()
                        .simultaneousGesture(dotsDragGesture)
                        .position(dotsPos)
                }
            }
            .coordinateSpace(name: "content")
            .ignoresSafeArea()
        }

        .sheet(isPresented: $showDiscovery) {
            ServerDiscoverySheet(isPresented: $showDiscovery)
                .presentationDetents([.height(480)])
                .presentationDragIndicator(.hidden)
        }
        .onAppear {
            if !settings.hasConfiguredServer { showDiscovery = true }
        }
    }

    // MARK: - Toggle button

    private var toggleButton: some View {
        Image(systemName: showTabBar ? "chevron.down" : "chevron.up")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 58, height: 58)
            .background(.thinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
    }

    // MARK: - Toggle gesture: tap = show/hide · drag = move (always)

    private var toggleGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("content"))
            .onChanged { value in
                let d = value.translation
                guard abs(d.width) > 6 || abs(d.height) > 6 else { return }
                if toggleDragOrigin == nil { toggleDragOrigin = togglePos }
                togglePos = CGPoint(
                    x: toggleDragOrigin!.x + d.width,
                    y: toggleDragOrigin!.y + d.height
                )
            }
            .onEnded { value in
                let d = value.translation
                if abs(d.width) <= 6 && abs(d.height) <= 6 {
                    withAnimation(.spring(duration: 0.35)) { showTabBar.toggle() }
                }
                toggleDragOrigin = nil
            }
    }

        // MARK: - 3-dots drag (tap falls through to Menu via simultaneousGesture)

        private var dotsDragGesture: some Gesture {
            DragGesture(minimumDistance: 10, coordinateSpace: .named("content"))
                .onChanged { value in
                    if dotsDragOrigin == nil { dotsDragOrigin = dotsPos }
                    dotsPos = CGPoint(
                        x: dotsDragOrigin!.x + value.translation.width,
                        y: dotsDragOrigin!.y + value.translation.height
                )
            }
            .onEnded { _ in dotsDragOrigin = nil }
    }
}
