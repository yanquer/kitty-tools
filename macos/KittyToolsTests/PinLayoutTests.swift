// 钉图在 1x 屏上的布局（issue #6：1x 外接屏上点「钉到屏幕」必闪退）。AppKit 布局时把带 autoresizing 约束的子视图吸到像素格上
// （2x 是半点、1x 是整点）；钉图原来在 layout() 里把缩放百分比摆到正中，窗口宽或高是奇数时正中落在半点上——1x 上被吸到整点、
// layout() 又摆回半点、约束又失效，显示周期反复「更新约束 → 布局」超过窗口里的视图数，AppKit 抛异常退出。
// 本机只有 2x 屏：把钉图的内容视图挪进一个 backingScaleFactor 报 1 的窗口（实测吸附跟着它走，修之前这里抛的就是崩溃报告里那个
// NSGenericException，测试宿主直接退出）。钉图摆在屏外、从不 makeKey，不读写偏好。

import AppKit
import Carbon.HIToolbox
import Testing

@testable import KittyTools

/// 构造仅交给钉图窗口的空格事件，不发到系统队列。
@MainActor func pinSpaceEvent(
  _ type: NSEvent.EventType, flags: NSEvent.ModifierFlags = [], repeating: Bool = false
) throws -> NSEvent {
  try #require(
    NSEvent.keyEvent(
      with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
      context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeating,
      keyCode: UInt16(kVK_Space)))
}

/// 构造交给钉图本地响应方法的滚动事件，不发到系统事件队列。
@MainActor func pinScrollEvent(
  _ delta: Int32, precise: Bool = false, option: Bool = false,
  phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil,
  at screenPoint: CGPoint? = nil, timestamp: TimeInterval? = nil
) throws -> NSEvent {
  let event = try #require(
    CGEvent(
      scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1,
      wheel1: delta, wheel2: 0, wheel3: 0))
  event.flags = option ? .maskAlternate : []
  if precise { event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1) }
  if let phase {
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
  }
  if let momentum {
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
  }
  if let screenPoint {
    event.location = CGPoint(
      x: screenPoint.x, y: CGDisplayBounds(CGMainDisplayID()).height - screenPoint.y)
  }
  if let timestamp { event.timestamp = UInt64(timestamp * 1_000_000_000) }
  return try #require(NSEvent(cgEvent: event))
}

/// 假装在 1x 屏上
private final class OneXWindow: NSWindow {
  override var backingScaleFactor: CGFloat { 1 }
}

@MainActor @Suite(.serialized)
struct PinLayoutTests {
  private static let image: CGImage = {
    let context = CGContext(
      data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
  }()

  /// 小幅位移连续累积，释放修饰键后的惯性也不会落到普通缩放。
  @Test func optionTrackpadAccumulatesAndKeepsMomentumOutOfZoom() throws {
    let board = PinBoard()
    let frame = CGRect(x: -20000, y: -20000, width: 200, height: 100)
    let pin = PinPanel(image: Self.image, frame: frame, board: board)
    let view = try #require(pin.contentView)
    pin.opacity = 0.5
    let begin = try pinScrollEvent(2, precise: true, option: true, phase: .began)
    #expect(begin.hasPreciseScrollingDeltas && begin.phase == .began)
    view.scrollWheel(with: begin)
    #expect(pin.opacityPercent == 50)
    view.scrollWheel(with: try pinScrollEvent(2, precise: true, option: true, phase: .changed))
    #expect(pin.opacityPercent == 51 && pin.frame == frame)
    view.scrollWheel(with: try pinScrollEvent(50, precise: true, phase: .changed))
    view.scrollWheel(with: try pinScrollEvent(0, precise: true, phase: .ended))
    let tail = try pinScrollEvent(40, precise: true, momentum: .begin)
    #expect(tail.momentumPhase == .began)
    view.scrollWheel(with: tail)
    view.scrollWheel(with: try pinScrollEvent(0, precise: true, momentum: .end))
    #expect(pin.opacityPercent == 51 && pin.frame == frame)
    view.scrollWheel(with: try pinScrollEvent(10, precise: true, phase: .began))
    #expect(pin.frame.size != frame.size && pin.opacityPercent == 51)
    #expect(!pin.isKeyWindow)
  }

  /// 在屏外经原生菜单和响应方法核对四条边的缩放位置。
  @Test func fixedScrollZoomAnchorsNearestEdge() throws {
    let board = PinBoard()
    let frame = CGRect(x: -20000, y: -20000, width: 200, height: 100)
    let edges: [(CGPoint, KeyPath<CGRect, CGFloat>)] = [
      (CGPoint(x: frame.minX + 6, y: frame.midY), \.minX),
      (CGPoint(x: frame.maxX - 6, y: frame.midY), \.maxX),
      (CGPoint(x: frame.midX, y: frame.minY + 6), \.minY),
      (CGPoint(x: frame.midX, y: frame.maxY - 6), \.maxY),
    ]
    for (point, edge) in edges {
      let pin = PinPanel(image: Self.image, frame: frame, board: board)
      let view = try #require(pin.contentView)
      let scroll = try pinScrollEvent(20, precise: true, phase: .began, at: point)
      let menu = try #require(view.menu(for: scroll)?.item(withTitle: "缩放锚点")?.submenu)
      #expect(menu.items.map(\.state) == [.on, .off])
      let fixed = try #require(menu.item(withTitle: "固定最近边"))
      #expect(NSApp.sendAction(try #require(fixed.action), to: fixed.target, from: fixed))
      #expect(
        view.menu(for: scroll)?.item(withTitle: "缩放锚点")?.submenu?.items.map(\.state) == [.off, .on])
      view.scrollWheel(with: scroll)
      #expect(pin.frame.width > frame.width)
      #expect(abs(pin.frame[keyPath: edge] - frame[keyPath: edge]) <= 0.5)
      #expect(!pin.isKeyWindow)
    }
  }

  /// 指针跨边时保留原锚点，新的触控板手势和间隔后的鼠标滚轮重新取边。
  @Test func fixedScrollZoomKeepsGestureAndWheelGroups() throws {
    let board = PinBoard()
    let frame = CGRect(x: -20000, y: -20000, width: 200, height: 100)
    let pin = PinPanel(image: Self.image, frame: frame, board: board)
    let view = try #require(pin.contentView)
    let action = try #require(view.accessibilityCustomActions()?.first { $0.name == "固定最近边" })
    #expect(action.handler?() == true)
    let left = CGPoint(x: frame.minX + 5, y: frame.midY)
    let start = try pinScrollEvent(0, precise: true, phase: .began, at: left)
    view.scrollWheel(with: start)
    #expect(pin.frame == frame)
    let right = CGPoint(x: frame.maxX - 5, y: frame.midY)
    view.scrollWheel(with: try pinScrollEvent(20, precise: true, phase: .changed, at: right))
    #expect(pin.frame.minX == frame.minX && pin.frame.width > frame.width)
    view.scrollWheel(with: try pinScrollEvent(0, precise: true, phase: .ended, at: right))
    let beforeMomentum = pin.frame
    view.scrollWheel(with: try pinScrollEvent(20, precise: true, momentum: .begin, at: right))
    #expect(pin.frame.minX == frame.minX && pin.frame.width > beforeMomentum.width)
    view.scrollWheel(with: try pinScrollEvent(0, precise: true, momentum: .end, at: right))
    let beforeNext = pin.frame
    let newRight = CGPoint(x: beforeNext.maxX - 5, y: beforeNext.midY)
    view.scrollWheel(with: try pinScrollEvent(-20, precise: true, phase: .began, at: newRight))
    #expect(abs(pin.frame.maxX - beforeNext.maxX) <= 0.5 && pin.frame.width < beforeNext.width)
    view.scrollWheel(with: try pinScrollEvent(20, precise: true, phase: .cancelled, at: left))

    pin.setFrame(frame, display: false)
    view.scrollWheel(with: try pinScrollEvent(1, at: left, timestamp: 1))
    let wheelRight = CGPoint(x: pin.frame.maxX - 5, y: pin.frame.midY)
    view.scrollWheel(with: try pinScrollEvent(1, at: wheelRight, timestamp: 1.1))
    #expect(pin.frame.minX == frame.minX)
    let beforeGap = pin.frame
    let afterGap = CGPoint(x: beforeGap.maxX - 5, y: beforeGap.midY)
    view.scrollWheel(with: try pinScrollEvent(-1, at: afterGap, timestamp: 1.5))
    #expect(abs(pin.frame.maxX - beforeGap.maxX) <= 0.5 && pin.frame.width < beforeGap.width)
  }

  /// 固定最近边不接管透明度、锁定和局部取景，取消后恢复指针模式。
  @Test func fixedScrollZoomRespectsOtherPinModes() throws {
    let board = PinBoard()
    let frame = CGRect(x: -20000, y: -20000, width: 200, height: 100)
    let pin = PinPanel(image: Self.image, frame: frame, board: board)
    let view = try #require(pin.contentView)
    let point = CGPoint(x: frame.minX + 5, y: frame.midY)
    let scroll = try pinScrollEvent(1, at: point)
    let actions = try #require(view.accessibilityCustomActions())
    let fixed = try #require(actions.first { $0.name == "固定最近边" })
    #expect(fixed.handler?() == true)
    pin.setLocked(true)
    view.scrollWheel(with: scroll)
    #expect(pin.frame == frame)
    view.scrollWheel(with: try pinScrollEvent(-5, option: true, at: point))
    #expect(pin.frame == frame && pin.opacityPercent == 75)
    pin.setLocked(false)
    let local = try #require(actions.first { $0.name == "局部放大" })
    #expect(local.handler?() == true)
    view.scrollWheel(with: scroll)
    #expect(pin.frame == frame)
    #expect((view.accessibilityValue() as? String)?.contains("局部放大 108%") == true)
    #expect(local.handler?() == true)
    let follow = try #require(actions.first { $0.name == "跟随指针" })
    #expect(follow.handler?() == true)
    #expect(
      view.menu(for: scroll)?.item(withTitle: "缩放锚点")?.submenu?.items.map(\.state) == [.on, .off])
    view.scrollWheel(with: scroll)
    #expect(pin.frame.width > frame.width)
  }

  // 回弹、滚轮缩放、原始大小都不卡在布局里，圆钮一直贴右上角、百分比居中（1x 上差不过半个点）
  @Test func pinLaysOutOnOneXScreens() throws {
    let board = PinBoard()
    // 报告里那种带小数的选区：窗口取整成 605 × 285，宽高都是奇数
    board.pin(
      Self.image,
      frame: CGRect(x: -20000.11, y: -20000.17, width: 604.80859375, height: 285.21875))
    defer { board.closeAll() }
    let panel = try #require(board.panels.first)
    panel.finishPopIn()  // 屏外的窗口 display link 不走，直接落到原位
    let view = try #require(panel.contentView)
    panel.contentView = NSView()
    let window = OneXWindow(
      contentRect: panel.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    let hud = try #require(view.subviews.first { $0 is HUDBar })
    let controls = try #require(
      view.subviews.first { !($0 is HUDBar) && !($0 is PinTextSelection) })

    /// 转一下 run loop：崩溃是显示周期（NSDisplayCycleFlush → 窗口 layoutIfNeeded）里抛的，光 layoutSubtreeIfNeeded 走不到
    func settle() {
      view.needsLayout = true
      RunLoop.main.run(until: .now + 0.05)
    }

    func expectPlaced(_ step: String, hudShown: Bool = false) {
      settle()
      let bounds = view.bounds
      #expect(abs(bounds.maxX - controls.frame.maxX - 6) <= 0.5, "\(step)：圆钮离右边 6")
      #expect(abs(bounds.maxY - controls.frame.maxY - 6) <= 0.5, "\(step)：圆钮离顶边 6")
      guard hudShown else { return }
      #expect(!hud.isHidden, "\(step)：百分比出来了")
      #expect(abs(hud.frame.midX - bounds.midX) <= 0.5, "\(step)：百分比横向居中")
      #expect(abs(hud.frame.midY - bounds.midY) <= 0.5, "\(step)：百分比竖向居中")
    }

    expectPlaced("钉上")
    // 回弹：窗口从 1.04 倍逐帧缩回原位
    let target = window.frame
    for scale in [1.04, 1.027, 1.013, 1.0] {
      window.setFrame(
        target.insetBy(dx: target.width * (1 - scale) / 2, dy: target.height * (1 - scale) / 2),
        display: true)
      expectPlaced("回弹 \(scale)")
    }

    let scroll = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 30, wheel2: 0,
        wheel3: 0))
    scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    view.scrollWheel(with: try #require(NSEvent(cgEvent: scroll)))
    #expect(window.frame.size != target.size, "滚轮缩放了")
    expectPlaced("滚轮缩放", hudShown: true)

    let event = try #require(
      NSEvent.mouseEvent(
        with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let actual = try #require(view.menu(for: event)?.items.first { $0.title == "原始大小" })
    NSApp.sendAction(try #require(actual.action), to: actual.target, from: actual)
    #expect(window.frame.size == target.size, "回到原始大小")
    expectPlaced("原始大小", hudShown: true)
  }
}
