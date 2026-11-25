// 图片四分之一转与镜像：像素和可编辑标注使用同一坐标变换，文字方向以可选元数据保留。

import AppKit
import OSLog

nonisolated enum ImageTransform {
  enum Action: String, CaseIterable, Sendable {
    case left, right, horizontal, vertical
    var title: String {
      switch self {
      case .left: "向左旋转 90°"
      case .right: "向右旋转 90°"
      case .horizontal: "水平翻转"
      case .vertical: "垂直翻转"
      }
    }
    var inverse: Self { self == .left ? .right : self == .right ? .left : self }
  }

  /// 仅保存正交矩阵；旧标注没有此可选字段时保持原来的绘制和命中行为。
  struct Pose: Codable, Equatable, Sendable {
    var a: CGFloat = 1
    var b: CGFloat = 0
    var c: CGFloat = 0
    var d: CGFloat = 1
    var tx: CGFloat = 0
    var ty: CGFloat = 0
    var affine: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }

    /// 从实际坐标变换保存六个分量，避免依赖系统矩阵的编码格式。
    init(_ value: CGAffineTransform = .identity) {
      a = value.a
      b = value.b
      c = value.c
      d = value.d
      tx = value.tx
      ty = value.ty
    }
  }

  struct Failure: LocalizedError {
    let errorDescription: String? = "图片变换未完成，请缩小图片后重试"
  }

  /// AppKit 左下原点的映射，四个操作均保持像素格，不插值或任意角度旋转。
  static func mapping(_ action: Action, size: CGSize) -> CGAffineTransform {
    switch action {
    case .left: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
    case .right: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
    case .horizontal: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
    case .vertical: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
    }
  }

  /// 多份撤销快照共享相同笔迹几何，只转换一次，避免每个历史步骤复制同一条长画笔。
  @MainActor static func annotations(
    _ batches: [[Annotation]], action: Action, size: CGSize
  ) -> [[Annotation]] {
    var cache: [UUID: Annotation] = [:]
    var sources: [UUID: Annotation] = [:]
    return batches.map { batch in
      batch.map { value in
        if let source = sources[value.id], source.shape == value.shape,
          source.textTransform == value.textTransform,
          source.caption?.orientation == value.caption?.orientation,
          (source.caption == nil) == (value.caption == nil), let changed = cache[value.id]
        {
          var reused = value
          reused.shape = changed.shape
          reused.textTransform = changed.textTransform
          reused.caption?.orientation = changed.caption?.orientation
          return reused
        }
        let changed = value.transformed(action, size: size)
        sources[value.id] = value
        cache[value.id] = changed
        return changed
      }
    }
  }

  /// 分配之前核对预算，超限作为明确失败记录，不能尝试分配巨型位图。
  static func validate(width: Int, height: Int) throws {
    guard width > 0, height > 0, Double(width) * Double(height) <= Double(ImageStore.maxPixels)
    else {
      Log.capture.error(
        "图片变换失败 stage=size width=\(width) height=\(height) limit=\(ImageStore.maxPixels)")
      throw Failure()
    }
  }

  /// 后台转换原像素，不把矢量标注烘焙进底图，失败保留可检索的阶段和原始输入规模。
  @concurrent static func image(_ image: CGImage, action: Action) async throws -> CGImage {
    try Task.checkCancellation()
    let turns = action == .left || action == .right
    let width = turns ? image.height : image.width
    let height = turns ? image.width : image.height
    try validate(width: width, height: height)
    let space =
      image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
      ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      Log.capture.error(
        "图片变换失败 stage=canvas action=\(action.rawValue, privacy: .public) width=\(width) height=\(height)"
      )
      throw Failure()
    }
    context.interpolationQuality = .none
    context.concatenate(mapping(action, size: CGSize(width: image.width, height: image.height)))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    try Task.checkCancellation()
    guard let result = context.makeImage() else {
      Log.capture.error("图片变换失败 stage=image action=\(action.rawValue, privacy: .public)")
      throw Failure()
    }
    return result
  }
}

extension Annotation {
  /// 与底图同向变换几何；文字和序号保留自己的坐标系，继续编辑时不丢内容或方向。
  func transformed(_ action: ImageTransform.Action, size: CGSize) -> Annotation {
    let matrix = ImageTransform.mapping(action, size: size)
    var next = self
    if let caption {
      var linear = matrix
      linear.tx = 0
      linear.ty = 0
      let combined = (caption.orientation?.affine ?? .identity).concatenating(linear)
      next.caption?.orientation = combined.isIdentity ? nil : ImageTransform.Pose(combined)
    }
    let reflect = action == .horizontal || action == .vertical
    switch shape {
    case .rectangle(let rect): next.shape = .rectangle(rect.applying(matrix))
    case .ellipse(let rect): next.shape = .ellipse(rect.applying(matrix))
    case .mosaic(let rect): next.shape = .mosaic(rect.applying(matrix))
    case .spotlight(let rect): next.shape = .spotlight(rect.applying(matrix))
    case .arrow(let from, let to, let bend):
      next.shape = .arrow(
        from: from.applying(matrix), to: to.applying(matrix),
        bend: CGVector(dx: bend.dx, dy: reflect ? -bend.dy : bend.dy))
    case .line(let from, let to, let bend):
      next.shape = .line(
        from: from.applying(matrix), to: to.applying(matrix),
        bend: CGVector(dx: bend.dx, dy: reflect ? -bend.dy : bend.dy))
    case .highlighter(let from, let to):
      next.shape = .highlighter(from: from.applying(matrix), to: to.applying(matrix))
    case .pen(let points): next.shape = .pen(points.map { $0.applying(matrix) })
    case .text, .counter:
      let combined = (textTransform?.affine ?? .identity).concatenating(matrix)
      next.textTransform = combined.isIdentity ? nil : ImageTransform.Pose(combined)
    }
    return next
  }

  /// 取出文字变换前的标注，绘制、命中和调整共同使用，避免双重变换。
  var untransformedText: Annotation {
    var copy = self
    copy.textTransform = nil
    return copy
  }
}
