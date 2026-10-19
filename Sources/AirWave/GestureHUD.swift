import AppKit
import SonarCore
import SwiftUI

/// A small floating badge near the top of the screen that shows what a gesture just did.
final class GestureHUD {
  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?

  func show(_ gesture: HandGesture, _ action: Action) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    panel.contentView = NSHostingView(rootView: HUDView(gesture: gesture, action: action))
    let size = NSSize(width: 230, height: 64)
    if let screen = NSScreen.main {
      let frame = screen.visibleFrame
      panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 24, width: size.width, height: size.height), display: true)
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.12
      panel.animator().alphaValue = 1
    }
    hideWork?.cancel()
    let work = DispatchWorkItem { [weak panel] in
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.35
        panel?.animator().alphaValue = 0
      }, completionHandler: { panel?.orderOut(nil) })
    }
    hideWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .statusBar
    panel.ignoresMouseEvents = true
    panel.hasShadow = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    return panel
  }
}

private struct HUDView: View {
  let gesture: HandGesture
  let action: Action

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: action.symbol)
        .font(.system(size: 22, weight: .semibold))
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(action == .none ? gesture.label : action.label)
          .font(.system(size: 15, weight: .semibold))
        Text(action == .none ? "No action set" : gesture.label)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
  }
}
