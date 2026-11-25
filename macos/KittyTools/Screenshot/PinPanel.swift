// 钉图：把截图钉在原位置当参考。不激活本 App、出现时不抢键盘（修旧版钉图抢焦点，§11 #48）；
// 拖动移动，滚轮 / 双指捏合以鼠标为锚点缩放，双击或 Esc 关闭（Esc、按键要先点一下钉图）。
// 按键和截图出图一致（体检 C9 D17）：⌘C 拷贝、O 识字并拷贝、⌘S 存储到快速保存的文件夹、⇧⌘S 另存为…、⌘0 原始大小、⌘W 关闭；
// 右键菜单：拷贝 / 识字并拷贝 / 翻译 / 存储到「桌面」/ 另存为… ｜ 透明度 / 原始大小 ｜ 关闭，VoiceOver 的自定义动作同一份（B45）。
// 透明度是 10–100% 的滑块（2026-10-03 用户要求，原来点一下换一档；对标 CleanShot 的钉图）：悬停圆钮点开、右键「透明度 ▸」里是同一行，
// 拖动实时生效。滑块放在菜单里：菜单是自己的窗口，钉图整个窗口按透明度变淡，滑块放进钉图里会跟着一起淡。
// 长截图时和选区相交的钉图让开（B40：不接鼠标、淡到 0.3，滚轮和自动滚动落到下面的窗口）。菜单栏可隐藏 / 显示、关闭全部。
// Whisker（mac-whisker §6 钉图）：圆角 10 + 系统阴影；钉上时窗口 1.04 → 1 弹簧回弹（超过半屏的只淡入）；悬停 0.3 s 后右上角淡入透明度 / 关闭两个
// 22 pt HUD 圆钮；缩放时中央 HUD 显示百分比、停手 0.7 s 淡出；关闭时缩到 0.92 并淡出 0.16 s。
// 不做点击穿透（穿透要全局抢一个热键才能再点回来）、不做钉图历史；钉图会出现在之后的截图里。
// 「钉住剪贴板里的图」（第二轮体检 F1）：从剪贴板取图（只读）、解码、找钉的位置在这里，AppDelegate.pinClipboard 串起来。
// 剪贴板里是文字时（issue #4，同贴图工具）把文字排成一张卡片图再钉（clipboardText / textCard），之后就是一张普通的钉图。

import AppKit
import Carbon.HIToolbox
import ImageIO
import OSLog
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable final class PinBoard {
  private(set) var panels: [PinPanel] = []
  private(set) var isHidden = false
  private(set) var focused: PinPanel?
  /// 拷贝 / 快速保存 / 另存为 / 识字并拷贝 / 翻译（动作、图、像素 / 点；.pin 不会来），由 AppDelegate 接到截图的输出上
  @ObservationIgnored var problem: (String) -> Void = { Island.announce($0) }
  @ObservationIgnored var output: @MainActor (RegionSelector.Action, CGImage, CGFloat) -> Void = {
    _, _, _ in
  }

  /// 继续标注由 AppDelegate 接到同一套标注遮罩。
  @ObservationIgnored var edit: (PinPanel) -> Void = { _ in }

  /// frame：截图时选区的位置（点，全局坐标）。钉图不抢键盘、VoiceOver 的焦点不在它上面：主动播报
  func pin(
    _ image: CGImage, frame: CGRect, original: CGImage? = nil,
    annotations: [Annotation] = [], scale: CGFloat? = nil
  ) {
    // 钉图归截图这个功能（Feature）：关着时哪条路过来（剪贴板、角落的缩略图…）都不钉，入口那边也藏了
    guard Feature.screenshot.isOn else { return }
    if isHidden { isHidden = false }
    focused = nil
    syncVisibility()
    let panel = PinPanel(
      image: image, frame: frame, board: self, original: original,
      annotations: annotations, scale: scale)
    panel.onProblem = { [weak self] in self?.problem($0) }
    panels.append(panel)
    panel.popIn()
    Island.announce("已钉到屏幕")
  }

  /// 长截图开始（体检 B40）：和选区相交的钉图让开——不接鼠标（滚轮、自动滚动的合成滚轮落到下面的窗口，不再缩放钉图）、
  /// 淡到 0.3（还看得见）。长截图滤掉了本 App，长图里本来就没有钉图
  func suspend(covering region: CGRect) {
    for panel in panels where panel.frame.intersects(region) { panel.suspend() }
  }

  /// 长截图结束（拷贝、存储、取消、出错都走这里）：放回原来的透明度、重新接鼠标
  func resume() {
    for panel in panels { panel.resume() }
  }

  func close(_ panel: PinPanel) {
    panel.cancelTransform()
    panels.removeAll { $0 === panel }
    if focused === panel { focused = nil }
    if panels.isEmpty { isHidden = false }
    panel.fadeOut()
    syncVisibility()
  }

  func closeAll() {
    for panel in panels {
      panel.cancelTransform()
      panel.fadeOut()
    }
    panels = []
    focused = nil
    isHidden = false
  }

  /// 隐藏全部优先于专注，恢复时仍保持用户选择的专注对象。
  func toggleHidden() {
    isHidden.toggle()
    syncVisibility()
  }

  /// 专注只隐藏其他钉图；关闭或退出专注后恢复仍存在的图片。
  func toggleFocus(_ panel: PinPanel) {
    guard panels.contains(where: { $0 === panel }) else { return }
    focused = focused === panel ? nil : panel
    Log.capture.notice("钉图专注变化 focused=\(self.focused?.windowNumber ?? -1) hidden=\(self.isHidden)")
    syncVisibility()
  }

  /// 编辑状态与收纳、专注统一协调，编辑关闭不能重新显示本应隐藏的图片。
  func setEditing(_ panel: PinPanel, _ editing: Bool) {
    guard panels.contains(where: { $0 === panel }) else { return }
    panel.isEditing = editing
    syncVisibility()
  }

  /// 只调整可见性，不激活应用或改变图片内容。
  private func syncVisibility() {
    for panel in panels {
      let show = !isHidden && !panel.isEditing && (focused == nil || focused === panel)
      if show, !panel.isVisible {
        panel.orderFrontRegardless()
      } else if !show, panel.isVisible {
        panel.orderOut(nil)
      }
    }
  }

}

// MARK: 钉住剪贴板里的图（第二轮体检 F1）

extension PinBoard {
  /// 剪贴板里要钉的图在哪
  nonisolated enum Source: Equatable, Sendable {
    /// 剪贴板上的图片数据（PNG、TIFF、JPEG、HEIC…，排在最前的那一种）
    case data(Data)
    /// 从访达复制的图片文件
    case file(URL)
  }

  /// 取出剪贴板里要钉的图（只读：不写剪贴板、不记历史；单测传临时的具名剪贴板）。有文件就只看文件，取第一个是图片的
  /// （按扩展名：png、jpg、heic、gif…）——访达复制文件时还会放一份文件图标的 TIFF，不能钉成图标，所以非图片文件就是没有；
  /// 没有文件才取第一种图片数据（网页「拷贝图像」常连着网址、HTML 一起放，带着文字也照样取图）。文字、色值、空 → nil
  static func clipboardImage(in pasteboard: NSPasteboard = .general) -> Source? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
      !files.isEmpty
    {
      let image = files.first {
        UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true
      }
      return image.map(Source.file)
    }
    let type = pasteboard.types?.first { UTType($0.rawValue)?.conforms(to: .image) == true }
    return type.flatMap { pasteboard.data(forType: $0) }.map(Source.data)
  }

  /// 剪贴板里要钉的文字（issue #4）：没有图片时才轮到它（AppDelegate 先问 clipboardImage）。有文件就不算（访达复制文件时
  /// 字符串是文件名）；密码管理器标了 ConcealedType 的不钉（不把密码明着摆在屏幕上，同剪贴板历史不记它）。
  /// 收拾同 pinnableText
  static func clipboardText(in pasteboard: NSPasteboard = .general) -> String? {
    let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
    if let files = pasteboard.readObjects(forClasses: [NSURL.self], options: options),
      !files.isEmpty
    {
      return nil
    }
    guard pasteboard.types?.contains(.init("org.nspasteboard.ConcealedType")) != true else {
      return nil
    }
    return pasteboard.string(forType: .string).flatMap(pinnableText)
  }

  /// 要钉的文字（纯函数；剪贴板、剪贴板历史里的文字条目共用）：首尾的空行去掉，行首的缩进留着；只有空白 → nil
  nonisolated static func pinnableText(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .newlines)
    return text.allSatisfy(\.isWhitespace) ? nil : text
  }

  /// 文字卡片最大多大（点）：宽 560、不超过可见区的六成；高到可见区的八成（clipboardFrame 超过八成才缩，卡片不会被缩小）
  static func textCardLimit(visible: CGRect) -> CGSize {
    CGSize(width: min(560, visible.width * 0.6), height: visible.height * 0.8)
  }

  /// 把文字排成一张卡片图（issue #4）：15 pt 系统字、行距 3.5（同翻译的阅读字号）、四周 12，底和字是系统的文本底色 / 文本色，
  /// 按 appearance 定深浅（钉的那一刻；之后换深浅色不跟，钉图本来就是一张图）。宽按最长的那行、超过 limit 折行；
  /// 高超过 limit 的截掉，最后一行末尾「…」。scale = 屏幕倍率（像素 ÷ 它 = 点，同钉图）。圆角由钉图自己裁。
  /// ponytail: 只排纯文字（不读 RTF / HTML 的格式、不认色值）；正文先截到 2 万字再排，几屏长的文字只钉得下开头
  static func textCard(
    _ text: String, scale: CGFloat, limit: CGSize, appearance: NSAppearance
  ) -> CGImage? {
    let padding: CGFloat = 12
    let font = NSFont.systemFont(ofSize: 15)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = 3.5
    let string = NSAttributedString(
      string: String(text.prefix(20_000)),
      attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.textColor])
    let inner = CGSize(width: limit.width - padding * 2, height: limit.height - padding * 2)
    let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    let fitted = string.boundingRect(
      with: CGSize(width: inner.width, height: .greatestFiniteMagnitude), options: options)
    // 放不下就截到整行（行高 = 字体行高 + 行距），最后一行由 truncatesLastVisibleLine 补「…」
    let line = NSLayoutManager().defaultLineHeight(for: font) + paragraph.lineSpacing
    let height =
      fitted.height <= inner.height ? fitted.height : (inner.height / line).rounded(.down) * line
    let size = CGSize(
      width: ceil(min(fitted.width, inner.width)) + padding * 2, height: ceil(height) + padding * 2)
    let (width, pixelHeight) = (Int(size.width * scale), Int(size.height * scale))
    guard width > 0, pixelHeight > 0,
      let context = CGContext(
        data: nil, width: width, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // 翻转成左上角原点，文字从上往下排
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    appearance.performAsCurrentDrawingAppearance {
      NSColor.textBackgroundColor.setFill()
      CGRect(origin: .zero, size: size).fill()
      string.draw(
        with: CGRect(x: padding, y: padding, width: inner.width, height: ceil(height)),
        options: options.union(.truncatesLastVisibleLine))
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
  }

  /// 解码（mac-native §3 @concurrent 第 1 类）：缩略图接口按原尺寸整张解码，顺带按 EXIF 方向转正；GIF 取第一帧。
  /// 解不出来（文件没了、ImageIO 不认的格式如 SVG）是 nil
  @concurrent nonisolated static func decode(_ source: Source) async -> CGImage? {
    let image =
      switch source {
      case .data(let data): CGImageSourceCreateWithData(data as CFData, nil)
      case .file(let url): CGImageSourceCreateWithURL(url as CFURL, nil)
      }
    guard let image,
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: decodedSide(width: width, height: height),
    ]
    return CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary)
  }

  /// 解码出来的长边（纯函数）：超过 ImageStore.maxPixels（约 8K × 5K，剪贴板记图的上限）的等比缩到它以内——钉图本来就
  /// 缩在屏幕 80% 以内，上亿像素的全景图整张解码要几百 MB、钉着就一直占着。
  /// ponytail: 这样缩过的钉图拷贝 / 存储出来的也是缩过的那张，要原图就从文件拿
  nonisolated static func decodedSide(width: Int, height: Int) -> Int {
    let fit = min(1, (Double(ImageStore.maxPixels) / Double(width * height)).squareRoot())
    return Int(Double(max(width, height)) * fit)
  }

  /// 钉在哪（纯函数）：同剪贴板面板「钉到屏幕」（ClipboardPanelModel.pinFrame：可见区中央、超过 80% 等比缩小），
  /// 第几张取「从中央往右下数第一个空格」——已有钉图的中心落在那一格上（±1 点）就往下一格，连按几次依次错开 24 点。
  /// 不按钉图总数排：截图原地钉的、别的屏上的、拖走了的不占格，不该把新的一张挤离中央（按总数排的话钉图一多就一路错到
  /// 屏幕外）；关掉、挪走一张就让出它那一格
  static func clipboardFrame(
    pixels: CGSize, scale: CGFloat, visible: CGRect, pinned: [CGRect]
  ) -> CGRect {
    func slot(_ index: Int) -> CGRect {
      ClipboardPanelModel.pinFrame(pixels: pixels, scale: scale, visible: visible, index: index)
    }
    var index = 0
    while pinned.contains(where: {
      abs($0.midX - slot(index).midX) <= 1 && abs($0.midY - slot(index).midY) <= 1
    }) {
      index += 1
    }
    return slot(index)
  }

  /// 钉回当初框的那一块（纯函数）：大小按图的宽高比重算——选区宽，太高的等比缩到可见区高度的 90%，顶边对齐选区、
  /// 底边不出可见区。截图的图和选区同比例，照原样；长截图记的是选区（比图矮得多），直接拿它当窗口大小会被压扁。
  /// 常驻缩略图钉长截图、截图历史 / 晾衣绳钉回去都走它
  static func restoredFrame(pixels: CGSize, source: CGRect, visible: CGRect) -> CGRect {
    let aspect = pixels.height / max(pixels.width, 1)
    var size = CGSize(width: source.width, height: source.width * aspect)
    if size.height > visible.height * 0.9 {
      size = CGSize(width: visible.height * 0.9 / aspect, height: visible.height * 0.9)
    }
    return CGRect(
      x: source.minX, y: max(source.maxY - size.height, visible.minY), width: size.width,
      height: size.height)
  }

  /// 历史里的一条钉到哪（纯函数，第四轮体检 E3）：当初那一块还在某块屏上就钉回去（restoredFrame，按那块屏的可见区）；
  /// 没记位置（老条目）、或那块屏已经拔掉（和现在哪块屏都不相交）就钉在 fallback 可见区的中央（clipboardFrame）。
  /// screens：每块屏的 frame 和 visibleFrame
  static func historyFrame(
    pixels: CGSize, scale: CGFloat, source: CGRect?, screens: [(frame: CGRect, visible: CGRect)],
    fallback: CGRect, pinned: [CGRect]
  ) -> CGRect {
    guard let source, let screen = screens.first(where: { $0.frame.intersects(source) }) else {
      return clipboardFrame(pixels: pixels, scale: scale, visible: fallback, pinned: pinned)
    }
    return restoredFrame(pixels: pixels, source: source, visible: screen.visible)
  }
}

/// 一张钉图。无边框窗口默认当不了 key（收不到 Esc / ⌘C），所以要子类化
final class PinPanel: NSPanel {
  private(set) var original: CGImage
  private let sourceImage: CGImage
  private(set) var isTransforming = false
  private var transformTask: Task<Void, Never>?
  private var transformUndo: [ImageTransform.Action] = []
  private var transformRedo: [ImageTransform.Action] = []
  var canUndoTransform: Bool { !transformUndo.isEmpty }
  var canRedoTransform: Bool { !transformRedo.isEmpty }
  var onProblem: (String) -> Void = { Island.announce($0) }
  let editingScale: CGFloat
  /// 输出沿用钉上时的显示倍率，与查看取景和编辑坐标倍率分别保存。
  let outputScale: CGFloat
  private(set) var annotations: [Annotation]
  private(set) var isMiniature = false
  private(set) var isLocked = false
  var isEditing = false
  private var expandedFrame: CGRect?

  /// 保留原图与可编辑标注，显示与输出仍使用合成图。
  init(
    image: CGImage, frame: CGRect, board: PinBoard, original: CGImage? = nil,
    annotations: [Annotation] = [], scale: CGFloat? = nil
  ) {
    self.original = original ?? image
    sourceImage = original ?? image
    self.annotations = annotations
    outputScale = CGFloat(image.width) / max(frame.width, 1)
    editingScale = scale ?? outputScale
    // styleMask 必须在 init 里一次写全：.nonactivatingPanel 初始化后再加不生效
    super.init(
      contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    // 透明窗口 + 圆角内容：系统阴影按内容形状算（改尺寸后 invalidateShadow）
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none
    let view = PinView(image: image, size: frame.size, board: board)
    contentView = view
    initialFirstResponder = view
    setFrame(frame, display: false)
  }

  /// 锁定只防止误操作，右键、复制、解锁和明确关闭入口始终保留。
  func setLocked(_ locked: Bool) {
    guard locked != isLocked else { return }
    if isTransforming { cancelTransform(reason: "lock") }
    finishPopIn()
    isLocked = locked
    (contentView as? PinView)?.lockChanged()
    Log.capture.notice("钉图锁定变化 window=\(self.windowNumber) locked=\(locked)")
    Island.announce(locked ? "钉图已锁定，可从右键菜单或 ⌘L 解锁" : "钉图已解锁")
  }

  /// 小卡片固定为 96×64 点，展开时恢复先前大小，并以当前位置的左上角为锚点。
  func setMiniature(_ miniature: Bool) {
    guard !isLocked, miniature != isMiniature else { return }
    finishPopIn()
    isMiniature = miniature
    if miniature {
      expandedFrame = frame
      setFrame(CGRect(x: frame.minX, y: frame.maxY - 64, width: 96, height: 64), display: true)
    } else if let expandedFrame {
      let visible = NSScreen.screens.first { $0.frame.intersects(frame) }?.visibleFrame
      setFrame(
        Self.restoredMiniature(frame, size: expandedFrame.size, within: visible), display: true)
      self.expandedFrame = nil
    }
    contentView?.needsDisplay = true
    invalidateShadow()
    Log.capture.notice("钉图收纳变化 window=\(self.windowNumber) miniature=\(miniature)")
  }

  /// 展开时夹回所在屏幕，屏外测试没有匹配屏幕时保持屏外位置。
  static func restoredMiniature(_ miniature: CGRect, size: CGSize, within visible: CGRect?)
    -> CGRect
  {
    var result = CGRect(
      x: miniature.minX, y: miniature.maxY - size.height, width: size.width, height: size.height)
    if let visible {
      result.origin.x = min(
        max(result.minX, visible.minX), max(visible.minX, visible.maxX - result.width))
      result.origin.y = min(
        max(result.minY, visible.minY), max(visible.minY, visible.maxY - result.height))
    }
    return result
  }

  /// 应用标注时只更新当前钉图，不新建副本，也不改动当前窗口位置。
  func applyEdits(image: CGImage, annotations: [Annotation], base: CGImage? = nil) {
    if let base {
      original = base
      transformUndo = []
      transformRedo = []
    }
    self.annotations = annotations
    replaceTransformedImage(image)
  }

  /// 原图与成品后台同向变换；撤销只存操作，避免保留一串大位图。
  func transform(_ action: ImageTransform.Action, replay: Int = 0) {
    guard !isLocked, !isTransforming, !isEditing, let composed = image else { return }
    setMiniature(false)
    finishPopIn()
    isTransforming = true
    let base = original
    let size = CGSize(
      width: CGFloat(base.width) / editingScale, height: CGFloat(base.height) / editingScale)
    let operation = UUID().uuidString
    Log.capture.notice(
      "钉图变换开始 operation=\(operation, privacy: .public) action=\(action.rawValue, privacy: .public)")
    transformTask = Task { [weak self] in
      do {
        let changedBase = try await ImageTransform.image(base, action: action)
        let changed =
          composed === base ? changedBase : try await ImageTransform.image(composed, action: action)
        guard !Task.isCancelled, let self else { return }
        original = changedBase
        annotations = annotations.map { $0.transformed(action, size: size) }
        if replay < 0, let previous = transformUndo.popLast() {
          transformRedo.append(previous)
        } else if replay > 0, let next = transformRedo.popLast() {
          transformUndo.append(next)
        } else {
          transformUndo.append(action)
          transformRedo = []
          if transformUndo.count > 100 { transformUndo.removeFirst() }
        }
        replaceTransformedImage(changed, resetView: true)
        isTransforming = false
        Log.capture.notice("钉图变换完成 operation=\(operation, privacy: .public)")
      } catch {
        guard !Task.isCancelled, let self else { return }
        isTransforming = false
        Log.capture.error(
          "钉图变换失败 operation=\(operation, privacy: .public) cause=\(String(reflecting: error), privacy: .public)"
        )
        onProblem(error.localizedDescription)
      }
    }
  }

  /// 逆操作恢复方向和标注，不改变原图来源或把标注烘焙进底图。
  func undoTransform() {
    if let action = transformUndo.last { transform(action.inverse, replay: -1) }
  }

  /// 重新采用被撤销的操作。
  func redoTransform() { if let action = transformRedo.last { transform(action, replay: 1) } }

  /// 关闭后旧任务不能重新改动已收起的窗口。
  func cancelTransform(reason: String = "close") {
    if isTransforming {
      Log.capture.notice("钉图变换取消 window=\(self.windowNumber) stage=\(reason, privacy: .public)")
    }
    transformTask?.cancel()
    transformTask = nil
    isTransforming = false
  }

  /// 保持当前查看倍率和中心，方向变化后按所在屏幕夹回可见范围。
  private func replaceTransformedImage(_ image: CGImage, resetView: Bool = false) {
    let old = self.image ?? image
    let oldFrame = frame
    let size = CGSize(
      width: oldFrame.width * CGFloat(image.width) / CGFloat(old.width),
      height: oldFrame.height * CGFloat(image.height) / CGFloat(old.height))
    (contentView as? PinView)?.replaceImage(image, resetView: resetView)
    if size != oldFrame.size {
      let desired = CGRect(
        x: oldFrame.midX - size.width / 2, y: oldFrame.midY - size.height / 2, width: size.width,
        height: size.height)
      let screen = NSScreen.screens.first { $0.frame.intersects(oldFrame) }?.visibleFrame
      setFrame(Self.restoredMiniature(desired, size: size, within: screen), display: true)
    }
    invalidateShadow()
  }

  /// 当前合成图供编辑完成后的完整性验证与输出使用。
  var image: CGImage? { (contentView as? PinView)?.image }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }

  /// 用户选的透明度（0.1–1，透明度滑块）：长截图让开时窗口临时淡到 0.3，结束后回到它
  var opacity: CGFloat = 1 {
    didSet { if !isSuspended { alphaValue = opacity } }
  }
  /// 长截图期间让开着（B40）
  private(set) var isSuspended = false

  func suspend() {
    guard !isSuspended else { return }
    finishPopIn()
    isSuspended = true
    ignoresMouseEvents = true
    alphaValue = min(opacity, 0.3)
  }

  func resume() {
    guard isSuspended else { return }
    isSuspended = false
    ignoresMouseEvents = false
    alphaValue = opacity
  }

  /// 钉上的回弹：终点（原位）、开始时间、逐帧驱动
  private var popping: (target: NSRect, began: CFTimeInterval)?
  private var popLink: CADisplayLink?
  /// 规则写的是 spring(0.35, 0.3)，§4 规定 bounce ≤ 0.25，按 pop 的上限取 0.25
  private static let popSpring = Spring(duration: 0.35, bounce: 0.25)

  /// 钉上：窗口从 1.04 倍（以中心为准）弹簧回到原位，同时 0.12 s 淡入。窗口帧动画只支持贝塞尔、实测冲不过头
  /// 也不认时长（同 OverlayPanel.squeezeIn），所以跟着显示器刷新逐帧按 SwiftUI Spring 算帧；不给内容图层放大
  /// （会被窗口边裁掉圆角）。减弱动态效果时只淡入；超过半屏的钉图也只淡入：几乎整屏的透明窗口逐帧改尺寸，窗口服务器
  /// 每帧都要重新分配几十 MB 的缓冲、按透明度重算阴影（ponytail: 大钉图没有回弹，要的话改成窗口定在 1.04 倍、只缩内容图层）
  func popIn() {
    let target = frame
    alphaValue = 0
    orderFrontRegardless()
    let reduced = Style.reduceMotion
    NSAnimationContext.runAnimationGroup { context in
      // 减弱动态效果时 pop 退成 0.2 s easeInOut 淡入（§7）
      context.duration = reduced ? 0.2 : Style.fadeIn
      context.timingFunction = CAMediaTimingFunction(name: reduced ? .easeInEaseOut : .easeOut)
      animator().alphaValue = opacity
    }
    let area = (self.screen ?? NSScreen.main)?.frame.size ?? .zero
    guard !reduced, target.width * target.height <= area.width * area.height / 2,
      let link = contentView?.displayLink(target: self, selector: #selector(stepPop))
    else { return }
    popping = (target, CACurrentMediaTime())
    setFrame(Self.scaled(target, by: 1.04), display: true)
    // 逐帧改窗口尺寸同 OverlayPanel.squeezeIn，一样最高 60 Hz（120 Hz 屏上 8.3 ms 一帧跟不上）
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    link.add(to: .main, forMode: .common)
    popLink = link
  }

  @objc private func stepPop(_ link: CADisplayLink) {
    guard let popping else { return finishPopIn() }
    let time = CACurrentMediaTime() - popping.began
    guard time < Self.popSpring.settlingDuration(target: 1.0, epsilon: 0.002) else {
      return finishPopIn()
    }
    let progress = Self.popSpring.value(target: 1.0, time: time)
    setFrame(Self.scaled(popping.target, by: 1.04 - 0.04 * progress), display: true)
  }

  /// 回弹停在原位：放完、用户开始拖动 / 缩放、关闭时都走这里（不然下一帧又把窗口按回去）
  func finishPopIn() {
    popLink?.invalidate()
    popLink = nil
    guard let target = popping?.target else { return }
    popping = nil
    setFrame(target, display: true)
    invalidateShadow()
  }

  /// 以中心为准缩放
  private static func scaled(_ rect: NSRect, by scale: CGFloat) -> NSRect {
    rect.insetBy(dx: rect.width * (1 - scale) / 2, dy: rect.height * (1 - scale) / 2)
  }

  /// 关闭：内容缩到 0.92（以中心为准）并淡出 0.16 s，完了再收窗口
  func fadeOut() {
    finishPopIn()
    if !Style.reduceMotion, let layer = contentView?.layer {
      let size = layer.bounds.size
      let shrink = CABasicAnimation(keyPath: "transform")
      shrink.fromValue = CATransform3DIdentity
      shrink.toValue = CATransform3DConcat(
        CATransform3DConcat(
          CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
          CATransform3DMakeScale(0.92, 0.92, 1)),
        CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
      shrink.duration = 0.16
      shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
      shrink.fillMode = .forwards
      shrink.isRemovedOnCompletion = false
      layer.add(shrink, forKey: "close")
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.16
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated { self?.orderOut(nil) }
    }
  }

  /// 截图可能盖到菜单栏：原位置出现，别被挪下来
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

private final class PinView: NSView {
  private(set) var image: CGImage
  private var localZoom = PinZoom()
  private var panStart: (point: CGPoint, center: CGPoint)?
  /// 钉上时的大小（点）：缩放的基准
  private var originalSize: CGSize
  private unowned let board: PinBoard

  /// 悬停后右上角的三个圆钮（透明度、锁定、关闭）：15 使用按钮栈，26 使用同一玻璃容器共用取样。
  private let controls: NSView
  private var lockButton: NSButton?
  /// 缩放时中央的百分比
  private let zoomHUD = HUDBar(radius: Style.Radius.control, height: 26)
  private let zoomLabel = NSTextField(labelWithString: "")
  private var hovering = false
  /// 每次缩放加一；停手 0.7 s 后只有最后一次负责收起百分比
  private var zoomGeneration = 0

  init(image: CGImage, size: CGSize, board: PinBoard) {
    self.image = image
    originalSize = size
    self.board = board
    let buttons = NSStackView()
    if #available(macOS 26, *) {
      let container = NSGlassEffectContainerView()  // spacing 0：不融合
      container.contentView = buttons
      buttons.autoresizingMask = [.width, .height]
      controls = container
    } else {
      controls = buttons
    }
    super.init(frame: CGRect(origin: .zero, size: size))
    wantsLayer = true
    let side = 22 - 2 * HUDBar.materialInset
    let opacity = circle(
      barButton(
        NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "透明度")!,
        tip: "透明度", action: #selector(showOpacity(_:)), size: CGSize(width: side, height: side)))
    let locking = barButton(
      NSImage(systemSymbolName: "lock.open", accessibilityDescription: "锁定钉图")!,
      tip: "锁定钉图（⌘L）", action: #selector(toggleLock), size: CGSize(width: side, height: side))
    lockButton = locking
    let close = circle(
      barButton(
        NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭")!, tip: "关闭",
        action: #selector(close), size: CGSize(width: side, height: side)))
    buttons.spacing = 6
    buttons.setViews([opacity, circle(locking), close], in: .trailing)
    // 圆钮贴右上角、各让 6，百分比在 showZoom 里居中；之后窗口改尺寸（回弹、缩放、原始大小）都靠掩码跟着走。
    // 别挪进 layout() 里摆（issue #6）：布局阶段改带 autoresizing 约束的子视图 frame 会让约束失效（layout() 的文档不许）；
    // super.layout() 又把它们吸到像素格上，居中落在半点时 1x 屏上吸到整点、再摆回半点，来回到 AppKit 抛异常闪退
    controls.frame = CGRect(
      origin: CGPoint(
        x: bounds.maxX - buttons.fittingSize.width - 6,
        y: bounds.maxY - buttons.fittingSize.height - 6),
      size: buttons.fittingSize)
    controls.autoresizingMask = [.minXMargin, .minYMargin]
    controls.alphaValue = 0
    controls.isHidden = true  // 看不见时也不能点到（点击不看透明度）
    addSubview(controls)
    // 和尺寸胶囊同一种小标签：SF Mono 12 semibold，字离两边一样远（量出来约 13）。内边距写 12 而不是尺寸胶囊的 8：
    // 那个 8 是到数字框的边，数字框里到字还有约 4.5；这里的标签框贴着字（写 8 的话字离边只有 9，比尺寸胶囊紧一截）
    zoomLabel.font = SizeField.font
    zoomLabel.textColor = Style.HUD.text
    zoomHUD.stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    zoomHUD.install([zoomLabel])
    zoomHUD.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
    zoomHUD.isHidden = true
    addSubview(zoomHUD)
    addTrackingArea(
      NSTrackingArea(
        rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
  }

  /// 22 pt HUD 圆钮（按钮边长 22 − 2 × HUDBar.materialInset：15 的材质内缩 0.5 → 21，26 的玻璃铺满 → 22）
  private func circle(_ button: NSButton) -> HUDBar {
    button.symbolConfiguration = .init(pointSize: 10, weight: .bold)
    button.contentTintColor = Style.HUD.text
    let bar = HUDBar(radius: 11, height: 22)
    bar.stack.edgeInsets = NSEdgeInsets()
    bar.install([button])
    bar.widthAnchor.constraint(equalToConstant: 22).isActive = true
    bar.heightAnchor.constraint(equalToConstant: 22).isActive = true
    return bar
  }

  override func mouseEntered(with event: NSEvent) {
    hovering = true
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(0.3))
      guard let self, self.hovering else { return }
      // 钉图太小时不放按钮（会盖住图）
      guard self.bounds.width >= 90, self.bounds.height >= 34 else { return }
      self.controls.isHidden = false
      self.fade(self.controls, in: true)
    }
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    fade(controls, in: false)
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(Style.fadeOut))
      guard let self, !self.hovering else { return }
      self.controls.isHidden = true
    }
  }

  private func fade(_ view: NSView, in show: Bool) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = show ? Style.fadeIn : Style.fadeOut
      view.animator().alphaValue = show ? 1 : 0
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    let crop = RegionSelector.pixelRect(
      localZoom.viewport,
      viewSize: CGSize(width: 1, height: 1),
      imageSize: CGSize(width: image.width, height: image.height))
    let miniature = panel?.isMiniature == true
    layer?.contents = localZoom.isEnabled && !miniature ? image.cropping(to: crop) : image
    layer?.contentsGravity = miniature ? .resizeAspect : .resize
    layer?.backgroundColor = miniature ? Style.HUD.solidFill.cgColor : nil
    layer?.cornerRadius = Style.Radius.card
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    layer?.borderWidth = Style.HUD.strokeWidth
    layer?.borderColor = NSColor.separatorColor.cgColor
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  private var panel: PinPanel? { window as? PinPanel }
  private var isFocused: Bool { panel.map { board.focused === $0 } ?? false }
  private var scale: CGFloat { CGFloat(image.width) / originalSize.width }

  override func mouseDown(with event: NSEvent) {
    if panel?.isLocked == true || panel?.isTransforming == true {
      window?.makeKey()
      return
    }
    if event.clickCount == 2 { return close() }
    panel?.finishPopIn()
    window?.makeKey()  // 点过之后 Esc、⌘C 才归它
    if localZoom.isEnabled, panel?.isMiniature != true, !event.modifierFlags.contains(.option) {
      panStart = (convert(event.locationInWindow, from: nil), localZoom.center)
      return
    }
    window?.performDrag(with: event)
  }

  /// 局部放大时拖动取景；按住 ⌥ 的拖动仍由系统移动整个窗口。
  override func mouseDragged(with event: NSEvent) {
    guard panel?.isLocked != true else { return }
    guard let panStart else { return super.mouseDragged(with: event) }
    let point = convert(event.locationInWindow, from: nil)
    localZoom.pan(
      from: panStart.center,
      by: CGSize(width: point.x - panStart.point.x, height: point.y - panStart.point.y),
      viewSize: bounds.size)
    needsDisplay = true
  }

  /// 松开只结束本次取景拖动。
  override func mouseUp(with event: NSEvent) { panStart = nil }

  /// 锁定时结束已有拖动并更新可见解锁按钮，不改变窗口位置或激活前台。
  func lockChanged() {
    panStart = nil
    let locked = panel?.isLocked == true
    let title = locked ? "解锁钉图" : "锁定钉图"
    lockButton?.image = NSImage(
      systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: title)
    lockButton?.toolTip = title + "（⌘L）"
    lockButton?.setAccessibilityLabel(title)
    lockButton?.contentTintColor = locked ? Style.Shot.accent : Style.HUD.text
    NSAccessibility.post(element: self, notification: .valueChanged)
  }

  /// 更换合成图时保留查看倍率，下一次重画使用新内容。
  func replaceImage(_ image: CGImage, resetView: Bool = false) {
    self.image = image
    if let panel {
      originalSize = CGSize(
        width: CGFloat(image.width) / panel.outputScale,
        height: CGFloat(image.height) / panel.outputScale)
    }
    if resetView {
      localZoom = PinZoom()
      panStart = nil
    }
    needsDisplay = true
  }

  override func scrollWheel(with event: NSEvent) {
    // 触控板给的是像素级增量，滚轮给的是行
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
    zoom(by: exp(delta * 0.01))
  }

  override func magnify(with event: NSEvent) { zoom(by: 1 + event.magnification) }

  /// 以鼠标为锚点缩放，保持宽高比：最小到原大的 10%、且宽高都不小于 24 点（原图本来更小就是原大），最大 5 倍
  private func zoom(by factor: CGFloat) {
    guard panel?.isTransforming != true, panel?.isLocked != true, panel?.isMiniature != true,
      let window, factor.isFinite,
      factor > 0
    else { return }
    panel?.finishPopIn()
    if localZoom.isEnabled {
      let point = convert(NSEvent.mouseLocation, from: nil)
      localZoom.zoom(
        by: factor,
        at: CGPoint(x: point.x / max(bounds.width, 1), y: point.y / max(bounds.height, 1)))
      needsDisplay = true
      showZoom(localZoom.magnification)
      return
    }
    let frame = window.frame
    let minimum = max(min(1, max(0.1, 24 / originalSize.width)), min(1, 24 / originalSize.height))
    let scale = min(max(frame.width / originalSize.width * factor, minimum), 5)
    let ratio = originalSize.width * scale / frame.width
    let anchor = NSEvent.mouseLocation
    window.setFrame(
      CGRect(
        x: anchor.x - (anchor.x - frame.minX) * ratio,
        y: anchor.y - (anchor.y - frame.minY) * ratio,
        width: originalSize.width * scale, height: originalSize.height * scale), display: true)
    window.invalidateShadow()
    showZoom(scale)
  }

  /// 中央 HUD 显示当前倍数，停手 0.7 s 后淡出
  private func showZoom(_ scale: CGFloat) {
    zoomLabel.stringValue = "\(Int((scale * 100).rounded()))%"
    zoomHUD.fit()
    zoomHUD.frame.origin = CGPoint(
      x: (bounds.width - zoomHUD.frame.width) / 2, y: (bounds.height - zoomHUD.frame.height) / 2)
    zoomHUD.isHidden = false
    zoomHUD.alphaValue = 1
    zoomGeneration += 1
    let generation = zoomGeneration
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(0.7))
      guard let self, self.zoomGeneration == generation else { return }
      self.fade(self.zoomHUD, in: false)
    }
  }

  override func keyDown(with event: NSEvent) {
    if Int(event.keyCode) == kVK_Escape { return close() }
    if !perform(event) { super.keyDown(with: event) }
  }

  /// 钉图是 key 时 ⌘ 组合键先到这里（体检 C9：⌘S 快速保存、⇧⌘S 另存为，同截图出图）
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard window?.isKeyWindow == true, perform(event) else {
      return super.performKeyEquivalent(with: event)
    }
    return true
  }

  /// 按键和右键菜单、VoiceOver 动作查同一张 commands 表（单测经 keyDown 锁住）：修饰键只比 ⌘⌃⌥⇧、不看大写锁定；
  /// 按住不放不反复执行（O 不反复识别、⌘S 不连存几张）
  private func perform(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
    guard
      let command = commands.first(where: {
        $0.keyCode == Int(event.keyCode) && $0.modifiers == flags
      })
    else { return false }
    if !event.isARepeat, commandIsEnabled(command.action) {
      NSApp.sendAction(command.action, to: self, from: nil)
    }
    return true
  }

  /// 一条命令：按键、右键菜单和 VoiceOver 自定义动作共用（透明度只在菜单里）
  private struct Command {
    let title: String
    /// 菜单上显示的键；keyCode 是实际认的物理键（nil = 没有按键）
    let key: String
    let keyCode: Int?
    let modifiers: NSEvent.ModifierFlags
    let action: Selector
  }

  /// 拷贝 / 识字并拷贝 / 翻译 / 存储到「桌面」/ 另存为… / 原始大小 / 关闭（体检 B41 C9 D17：截图家族同名同键）
  private var commands: [Command] {
    [
      Command(
        title: "拷贝", key: "c", keyCode: kVK_ANSI_C, modifiers: .command,
        action: #selector(copyImage)),
      Command(
        title: "识字并拷贝", key: "o", keyCode: kVK_ANSI_O, modifiers: [],
        action: #selector(recognizeText)),
      Command(
        title: "查看识字结果", key: "o", keyCode: kVK_ANSI_O, modifiers: .shift,
        action: #selector(inspectText)),
      Command(
        title: "翻译", key: "", keyCode: nil, modifiers: [], action: #selector(translateImage)),
      Command(
        title: ScreenshotOutput.saveTitle, key: "s", keyCode: kVK_ANSI_S, modifiers: .command,
        action: #selector(saveImage)),
      Command(
        title: "另存为…", key: "s", keyCode: kVK_ANSI_S, modifiers: [.command, .shift],
        action: #selector(saveImageAs)),
      Command(
        title: "继续标注", key: "e", keyCode: kVK_ANSI_E, modifiers: .command,
        action: #selector(editImage)),
      Command(
        title: localZoom.isEnabled ? "退出局部放大" : "局部放大", key: "z", keyCode: kVK_ANSI_Z,
        modifiers: .command,
        action: #selector(toggleLocalZoom)),
      Command(
        title: panel?.isMiniature == true ? "展开钉图" : "收起为小卡片", key: "m", keyCode: kVK_ANSI_M,
        modifiers: .command,
        action: #selector(toggleMiniature)),
      Command(
        title: isFocused ? "退出专注" : "专注这张钉图", key: "f", keyCode: kVK_ANSI_F, modifiers: .command,
        action: #selector(toggleFocus)),
      Command(
        title: panel?.isLocked == true ? "解锁钉图" : "锁定钉图", key: "l", keyCode: kVK_ANSI_L,
        modifiers: .command, action: #selector(toggleLock)),
      Command(
        title: "原始大小", key: "0", keyCode: kVK_ANSI_0, modifiers: .command,
        action: #selector(actualSize)),
      Command(
        title: "向左旋转 90°", key: "", keyCode: nil, modifiers: [], action: #selector(rotateLeft)),
      Command(
        title: "向右旋转 90°", key: "", keyCode: nil, modifiers: [], action: #selector(rotateRight)),
      Command(
        title: "水平翻转", key: "", keyCode: nil, modifiers: [], action: #selector(flipHorizontal)),
      Command(title: "垂直翻转", key: "", keyCode: nil, modifiers: [], action: #selector(flipVertical)),
      Command(
        title: "撤销图像变换", key: "", keyCode: nil, modifiers: [], action: #selector(undoTransform)),
      Command(
        title: "重做图像变换", key: "", keyCode: nil, modifiers: [], action: #selector(redoTransform)),
      Command(
        title: "关闭", key: "w", keyCode: kVK_ANSI_W, modifiers: .command, action: #selector(close)),
    ]
  }

  /// 锁定期间拒绝改变几何和编辑，复制、识字、透明度、专注、解锁与明确关闭仍可用。
  private func commandIsEnabled(_ action: Selector) -> Bool {
    if panel?.isTransforming == true { return action == #selector(close) }
    if action == #selector(undoTransform), panel?.canUndoTransform != true { return false }
    if action == #selector(redoTransform), panel?.canRedoTransform != true { return false }
    guard panel?.isLocked == true else { return true }
    return ![
      #selector(editImage), #selector(toggleLocalZoom), #selector(toggleMiniature),
      #selector(actualSize), #selector(rotateLeft), #selector(rotateRight),
      #selector(flipHorizontal), #selector(flipVertical), #selector(undoTransform),
      #selector(redoTransform),
    ].contains(action)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let items = commands.map { command in
      let item = NSMenuItem(
        title: command.title, action: command.action, keyEquivalent: command.key)
      item.keyEquivalentModifierMask = command.modifiers
      item.target = self
      item.isEnabled = commandIsEnabled(command.action)
      // 翻译这个功能关着（Feature）：藏起来（不从列表里拿掉——下面按位置分组）
      item.isHidden = command.action == #selector(translateImage) && !Feature.translate.isOn
      return item
    }
    items[0..<6].forEach(menu.addItem)
    menu.addItem(.separator())
    let opacity = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
    opacity.submenu = opacityMenu()
    menu.addItem(opacity)
    for item in items[6..<18] { menu.addItem(item) }
    if let zoomItem = menu.items.first(where: { $0.action == #selector(toggleLocalZoom) }) {
      zoomItem.state = localZoom.isEnabled ? .on : .off
      zoomItem.toolTip = "固定窗口大小，滚轮放大、拖动查看；⌥ 拖动移动窗口。复制与保存保留完整图片。"
    }
    for item in menu.items {
      if item.action == #selector(toggleLock) { item.state = panel?.isLocked == true ? .on : .off }
      if item.action == #selector(toggleFocus) { item.state = isFocused ? .on : .off }
      if item.action == #selector(toggleMiniature) {
        item.state = panel?.isMiniature == true ? .on : .off
      }
    }
    menu.addItem(.separator())
    menu.addItem(items[18])
    return menu
  }

  // MARK: 无障碍（mac-whisker §7，体检 B45）：钉图平时没有看得见的按钮，整张图是一个元素，操作都在自定义动作里

  override func isAccessibilityElement() -> Bool { true }
  override func accessibilityRole() -> NSAccessibility.Role? { .image }
  override func accessibilityLabel() -> String? { "钉图" }

  override func accessibilityValue() -> Any? {
    let size = window?.frame.size ?? bounds.size
    let percent = Int(((panel?.opacity ?? 1) * 100).rounded())
    return "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) 点，透明度 \(percent)%"
      + (localZoom.isEnabled ? "，局部放大 \(Int(localZoom.magnification * 100))%" : "")
      + (panel?.isMiniature == true ? "，已收纳" : "")
      + (isFocused ? "，专注" : "")
      + (panel?.isLocked == true ? "，已锁定" : "")
  }

  override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
    commands.filter {
      commandIsEnabled($0.action)
        && ($0.action != #selector(translateImage) || Feature.translate.isOn)
    }.map {
      command in
      let action = command.action
      return NSAccessibilityCustomAction(name: command.title) { [weak self] in
        MainActor.assumeIsolated { NSApp.sendAction(action, to: self, from: nil) }
      }
    }
  }

  /// 右键与旁白共享四个显式图像方向操作。
  @objc private func rotateLeft() { panel?.transform(.left) }
  /// 顺时针旋转。
  @objc private func rotateRight() { panel?.transform(.right) }
  /// 水平镜像。
  @objc private func flipHorizontal() { panel?.transform(.horizontal) }
  /// 垂直镜像。
  @objc private func flipVertical() { panel?.transform(.vertical) }
  /// 撤销最近一次方向变化。
  @objc private func undoTransform() { panel?.undoTransform() }
  /// 重做最近一次方向变化。
  @objc private func redoTransform() { panel?.redoTransform() }

  /// 快捷键、右键与旁白共享锁定入口，不使用点击穿透或额外全局热键。
  @objc private func toggleLock() { if let panel { panel.setLocked(!panel.isLocked) } }

  /// 收纳仅改变查看方式，原始图片和编辑标注保留在同一对象中。
  @objc private func toggleMiniature() { if let panel { panel.setMiniature(!panel.isMiniature) } }

  /// 专注由钉图集合统一控制，菜单、快捷键和旁白共用此动作。
  @objc private func toggleFocus() { if let panel { board.toggleFocus(panel) } }

  /// 打开现有标注遮罩；是否应用由用户在遮罩中确认。
  @objc private func editImage() { if let panel, !panel.isLocked { board.edit(panel) } }

  /// 查看模式只改变取景，不改变复制、识字和保存所用的完整图像。
  @objc private func toggleLocalZoom() {
    guard panel?.isLocked != true else { return }
    panel?.setMiniature(false)
    localZoom.toggle()
    panStart = nil
    needsDisplay = true
    Island.announce(localZoom.isEnabled ? "局部放大：滚轮放大、拖动查看，⌥ 拖动移动窗口" : "已显示完整图片")
  }

  @objc private func copyImage() { board.output(.copy, image, scale) }
  @objc private func saveImage() { board.output(.save, image, scale) }
  @objc private func saveImageAs() { board.output(.saveAs, image, scale) }
  /// 查看钉图的识字结果，不改变当前钉图。
  @objc private func inspectText() { board.output(.inspect, image, scale) }

  @objc private func recognizeText() { board.output(.recognize, image, scale) }
  @objc private func translateImage() { board.output(.translate, image, scale) }

  /// 只有一行透明度滑块的菜单：右键「透明度 ▸」的子菜单、圆钮弹出的都是它
  private func opacityMenu() -> NSMenu {
    let menu = NSMenu()
    let item = NSMenuItem()
    item.view = OpacitySlider(panel: panel)
    menu.addItem(item)
    return menu
  }

  /// 圆钮：在它下面弹出透明度滑块（同下拉菜单，左边对齐）；菜单开着时按钮保持按下的样子
  @objc private func showOpacity(_ sender: NSButton) {
    let anchor = convert(sender.bounds, from: sender)
    opacityMenu().popUp(
      positioning: nil, at: CGPoint(x: anchor.minX, y: anchor.minY - 4), in: self)
  }

  /// 回到钉上时的大小，左上角不动
  @objc private func actualSize() {
    guard panel?.isLocked != true else { return }
    panel?.setMiniature(false)
    localZoom = PinZoom()
    needsDisplay = true
    guard let window else { return }
    panel?.finishPopIn()
    let frame = window.frame
    window.setFrame(
      CGRect(
        x: frame.minX, y: frame.maxY - originalSize.height, width: originalSize.width,
        height: originalSize.height), display: true)
    window.invalidateShadow()
    showZoom(1)
  }

  @objc private func close() {
    if let panel { board.close(panel) }
  }
}

/// 菜单里的透明度一行：滑块 + 右边的百分比，拖动时钉图跟着变。最低 10%：到 0 钉图就看不见了，
/// 却还挡着下面的鼠标、悬停圆钮也跟着看不见，只能从菜单栏「关闭全部钉图」找回来
private final class OpacitySlider: NSView {
  private weak var panel: PinPanel?
  private let slider: NSSlider
  private let label = NSTextField(labelWithString: "")

  init(panel: PinPanel?) {
    self.panel = panel
    // 这个构造出来是横的、连续的（拖动中一直发 action，钉图跟着手变）
    slider = NSSlider(
      value: ((panel?.opacity ?? 1) * 100).rounded(), minValue: 10, maxValue: 100, target: nil,
      action: nil)
    super.init(frame: CGRect(x: 0, y: 0, width: 224, height: 30))
    slider.target = self
    slider.action = #selector(changed)
    // 跟随系统时系统自己取 AccentColor（品牌粉），选了 8 色之一时 AppKit 控件不跟，填充色单独给（mac-whisker §3「颜色」）
    slider.trackFillColor = NSColor(Style.brand)
    slider.setAccessibilityLabel("透明度")
    label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    label.textColor = .secondaryLabelColor
    label.alignment = .right
    for view in [slider, label] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }
    // 左右各 14：和菜单项的文字对齐
    NSLayoutConstraint.activate([
      slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      slider.centerYAnchor.constraint(equalTo: centerYAnchor),
      label.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      label.widthAnchor.constraint(equalToConstant: 36),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    showValue()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// 按整数百分比设
  @objc private func changed() {
    panel?.opacity = slider.doubleValue.rounded() / 100
    showValue()
  }

  private func showValue() {
    label.stringValue = "\(Int(slider.doubleValue.rounded()))%"
    slider.setAccessibilityValueDescription(label.stringValue)
  }
}
