// 窗口管理的动作目录，覆盖分屏、细分网格、跨屏、尺寸与多窗口操作。

import AppKit
import Carbon.HIToolbox

/// 稳定动作名用于快捷键、启动器和设置文件，布局坐标统一采用左上原点。
nonisolated enum WindowLayoutAction: String, CaseIterable, Identifiable, Codable {
  case leftHalf, rightHalf, maximize, maximizeHeight, previousDisplay
  case nextDisplay, larger, smaller, bottomHalf, topHalf
  case center, bottomLeft, bottomRight, topLeft, topRight
  case restore, firstThird, firstTwoThirds, centerThird, lastTwoThirds
  case lastThird, moveLeft, moveRight, moveUp, moveDown
  case almostMaximize, centerHalf, firstFourth, secondFourth, thirdFourth
  case lastFourth, firstThreeFourths, lastThreeFourths, topLeftSixth, topCenterSixth
  case topRightSixth, bottomLeftSixth, bottomCenterSixth, bottomRightSixth, specified
  case reverseAll, topLeftNinth, topCenterNinth, topRightNinth, middleLeftNinth
  case middleCenterNinth, middleRightNinth, bottomLeftNinth, bottomCenterNinth, bottomRightNinth
  case topLeftThird, topRightThird, bottomLeftThird, bottomRightThird, topLeftEighth
  case topCenterLeftEighth, topCenterRightEighth, topRightEighth, bottomLeftEighth,
    bottomCenterLeftEighth
  case bottomCenterRightEighth, bottomRightEighth, tileAll, cascadeAll, leftTodo
  case rightTodo, cascadeActiveApp, centerProminently, doubleHeightUp, doubleHeightDown
  case doubleWidthLeft, doubleWidthRight, halveHeightUp, halveHeightDown, halveWidthLeft
  case halveWidthRight, largerWidth, smallerWidth, largerHeight, smallerHeight
  case centerTwoThirds, centerThreeFourths, tileActiveApp, topVerticalThird, middleVerticalThird
  case bottomVerticalThird, topVerticalTwoThirds, bottomVerticalTwoThirds, topLeftTwelfth,
    topCenterLeftTwelfth
  case topCenterRightTwelfth, topRightTwelfth, middleLeftTwelfth, middleCenterLeftTwelfth,
    middleCenterRightTwelfth
  case middleRightTwelfth, bottomLeftTwelfth, bottomCenterLeftTwelfth, bottomCenterRightTwelfth,
    bottomRightTwelfth
  case topLeftSixteenth, topCenterLeftSixteenth, topCenterRightSixteenth, topRightSixteenth,
    upperMiddleLeftSixteenth
  case upperMiddleCenterLeftSixteenth, upperMiddleCenterRightSixteenth, upperMiddleRightSixteenth,
    lowerMiddleLeftSixteenth, lowerMiddleCenterLeftSixteenth
  case lowerMiddleCenterRightSixteenth, lowerMiddleRightSixteenth, bottomLeftSixteenth,
    bottomCenterLeftSixteenth, bottomCenterRightSixteenth
  case bottomRightSixteenth, displayOne, displayTwo, displayThree, displayFour
  case displayFive, displaySix, displaySeven, displayEight, displayNine
  case tileRows, tileColumns, cycleStackedWindows, cycleStackedWindowsBackward, firstVerticalEighth
  case secondVerticalEighth, thirdVerticalEighth, fourthVerticalEighth, fifthVerticalEighth,
    sixthVerticalEighth
  case seventhVerticalEighth, lastVerticalEighth, firstVerticalSixth, secondVerticalSixth,
    thirdVerticalSixth
  case fourthVerticalSixth, fifthVerticalSixth, lastVerticalSixth

  var id: String { rawValue }

  /// 指定显示器的入口同时显示编号和系统名称，未列出的目标明确标为不可用。
  @MainActor var displayTitle: String {
    guard let index = WindowLayout.displayNumber(self) else { return title }
    let screens = WindowLayout.orderedScreens
    guard screens.indices.contains(index) else { return title + "（当前不可用）" }
    return title + " · " + screens[index].localizedName
  }

  /// 选择器已知目标屏幕方向，名称直接描述将要执行的竖屏区域。
  @MainActor func title(portrait: Bool) -> String {
    if WindowLayout.displayNumber(self) != nil { return displayTitle }
    guard portrait else { return title }
    switch self {
    case .firstThird: return "上部三分之一"
    case .lastThird: return "下部三分之一"
    case .firstTwoThirds: return "上部三分之二"
    case .lastTwoThirds: return "下部三分之二"
    case .firstThreeFourths: return "上部四分之三"
    case .lastThreeFourths: return "下部四分之三"
    case .firstFourth, .secondFourth, .thirdFourth, .lastFourth:
      return title.replacingOccurrences(of: "列", with: "行")
    default: break
    }
    if rawValue.contains("VerticalEighth") || rawValue.contains("VerticalSixth") {
      return title.replacingOccurrences(of: "条", with: "行")
    }
    let fractions = [("Sixth", "六分之一"), ("Eighth", "八分之一"), ("Twelfth", "十二分之一")]
    guard let fraction = fractions.first(where: { rawValue.hasSuffix($0.0) }),
      let unit = unitRect(portrait: true)
    else { return title }
    let rows = Int((1 / unit.height).rounded())
    let columns = Int((1 / unit.width).rounded())
    let row = Int((unit.minY / unit.height).rounded())
    let column = Int((unit.minX / unit.width).rounded())
    let rowNames = rows == 3 ? ["上排", "中排", "下排"] : ["上排", "第二排", "第三排", "下排"]
    let columnNames = columns == 2 ? ["左侧", "右侧"] : ["左侧", "中间", "右侧"]
    guard rowNames.indices.contains(row), columnNames.indices.contains(column) else { return title }
    return rowNames[row] + columnNames[column] + fraction.1
  }

  /// 在设置、菜单和启动器里共用的中文动作名称。
  var title: String {
    switch self {
    case .leftHalf: "左半屏"
    case .rightHalf: "右半屏"
    case .maximize: "最大化"
    case .maximizeHeight: "高度最大化"
    case .previousDisplay: "上一个显示器"
    case .nextDisplay: "下一个显示器"
    case .larger: "放大窗口"
    case .smaller: "缩小窗口"
    case .bottomHalf: "下半屏"
    case .topHalf: "上半屏"
    case .center: "居中"
    case .bottomLeft: "左下四分之一"
    case .bottomRight: "右下四分之一"
    case .topLeft: "左上四分之一"
    case .topRight: "右上四分之一"
    case .restore: "还原窗口"
    case .firstThird: "左侧三分之一"
    case .firstTwoThirds: "左侧三分之二"
    case .centerThird: "中间三分之一"
    case .lastTwoThirds: "右侧三分之二"
    case .lastThird: "右侧三分之一"
    case .moveLeft: "移到左边缘"
    case .moveRight: "移到右边缘"
    case .moveUp: "移到上边缘"
    case .moveDown: "移到下边缘"
    case .almostMaximize: "接近最大化"
    case .centerHalf: "中间半屏"
    case .firstFourth: "第一列四分之一"
    case .secondFourth: "第二列四分之一"
    case .thirdFourth: "第三列四分之一"
    case .lastFourth: "第四列四分之一"
    case .firstThreeFourths: "左侧四分之三"
    case .lastThreeFourths: "右侧四分之三"
    case .topLeftSixth: "上排左侧六分之一"
    case .topCenterSixth: "上排中间六分之一"
    case .topRightSixth: "上排右侧六分之一"
    case .bottomLeftSixth: "下排左侧六分之一"
    case .bottomCenterSixth: "下排中间六分之一"
    case .bottomRightSixth: "下排右侧六分之一"
    case .specified: "自定义尺寸"
    case .reverseAll: "左右镜像所有窗口"
    case .topLeftNinth: "上排左侧九分之一"
    case .topCenterNinth: "上排中间九分之一"
    case .topRightNinth: "上排右侧九分之一"
    case .middleLeftNinth: "中排左侧九分之一"
    case .middleCenterNinth: "中排中间九分之一"
    case .middleRightNinth: "中排右侧九分之一"
    case .bottomLeftNinth: "下排左侧九分之一"
    case .bottomCenterNinth: "下排中间九分之一"
    case .bottomRightNinth: "下排右侧九分之一"
    case .topLeftThird: "上排左侧三分之一"
    case .topRightThird: "上排右侧三分之一"
    case .bottomLeftThird: "下排左侧三分之一"
    case .bottomRightThird: "下排右侧三分之一"
    case .topLeftEighth: "上排左侧八分之一"
    case .topCenterLeftEighth: "上排中左八分之一"
    case .topCenterRightEighth: "上排中右八分之一"
    case .topRightEighth: "上排右侧八分之一"
    case .bottomLeftEighth: "下排左侧八分之一"
    case .bottomCenterLeftEighth: "下排中左八分之一"
    case .bottomCenterRightEighth: "下排中右八分之一"
    case .bottomRightEighth: "下排右侧八分之一"
    case .tileAll: "平铺所有窗口"
    case .cascadeAll: "层叠所有窗口"
    case .leftTodo: "左侧待办窗口"
    case .rightTodo: "右侧待办窗口"
    case .cascadeActiveApp: "层叠当前 App 的窗口"
    case .centerProminently: "显著居中"
    case .doubleHeightUp: "向上加倍高度"
    case .doubleHeightDown: "向下加倍高度"
    case .doubleWidthLeft: "向左加倍宽度"
    case .doubleWidthRight: "向右加倍宽度"
    case .halveHeightUp: "保留上半高度"
    case .halveHeightDown: "保留下半高度"
    case .halveWidthLeft: "保留左半宽度"
    case .halveWidthRight: "保留右半宽度"
    case .largerWidth: "增加宽度"
    case .smallerWidth: "减小宽度"
    case .largerHeight: "增加高度"
    case .smallerHeight: "减小高度"
    case .centerTwoThirds: "中间三分之二"
    case .centerThreeFourths: "中间四分之三"
    case .tileActiveApp: "平铺当前 App 的窗口"
    case .topVerticalThird: "上部三分之一"
    case .middleVerticalThird: "中部三分之一"
    case .bottomVerticalThird: "下部三分之一"
    case .topVerticalTwoThirds: "上部三分之二"
    case .bottomVerticalTwoThirds: "下部三分之二"
    case .topLeftTwelfth: "上排左侧十二分之一"
    case .topCenterLeftTwelfth: "上排中左十二分之一"
    case .topCenterRightTwelfth: "上排中右十二分之一"
    case .topRightTwelfth: "上排右侧十二分之一"
    case .middleLeftTwelfth: "中排左侧十二分之一"
    case .middleCenterLeftTwelfth: "中排中左十二分之一"
    case .middleCenterRightTwelfth: "中排中右十二分之一"
    case .middleRightTwelfth: "中排右侧十二分之一"
    case .bottomLeftTwelfth: "下排左侧十二分之一"
    case .bottomCenterLeftTwelfth: "下排中左十二分之一"
    case .bottomCenterRightTwelfth: "下排中右十二分之一"
    case .bottomRightTwelfth: "下排右侧十二分之一"
    case .topLeftSixteenth: "上排左侧十六分之一"
    case .topCenterLeftSixteenth: "上排中左十六分之一"
    case .topCenterRightSixteenth: "上排中右十六分之一"
    case .topRightSixteenth: "上排右侧十六分之一"
    case .upperMiddleLeftSixteenth: "第二排左侧十六分之一"
    case .upperMiddleCenterLeftSixteenth: "第二排中左十六分之一"
    case .upperMiddleCenterRightSixteenth: "第二排中右十六分之一"
    case .upperMiddleRightSixteenth: "第二排右侧十六分之一"
    case .lowerMiddleLeftSixteenth: "第三排左侧十六分之一"
    case .lowerMiddleCenterLeftSixteenth: "第三排中左十六分之一"
    case .lowerMiddleCenterRightSixteenth: "第三排中右十六分之一"
    case .lowerMiddleRightSixteenth: "第三排右侧十六分之一"
    case .bottomLeftSixteenth: "下排左侧十六分之一"
    case .bottomCenterLeftSixteenth: "下排中左十六分之一"
    case .bottomCenterRightSixteenth: "下排中右十六分之一"
    case .bottomRightSixteenth: "下排右侧十六分之一"
    case .displayOne: "移到显示器 1"
    case .displayTwo: "移到显示器 2"
    case .displayThree: "移到显示器 3"
    case .displayFour: "移到显示器 4"
    case .displayFive: "移到显示器 5"
    case .displaySix: "移到显示器 6"
    case .displaySeven: "移到显示器 7"
    case .displayEight: "移到显示器 8"
    case .displayNine: "移到显示器 9"
    case .tileRows: "按行平铺窗口"
    case .tileColumns: "按列平铺窗口"
    case .cycleStackedWindows: "切换重叠窗口"
    case .cycleStackedWindowsBackward: "反向切换重叠窗口"
    case .firstVerticalEighth: "第 1 条八分之一"
    case .secondVerticalEighth: "第 2 条八分之一"
    case .thirdVerticalEighth: "第 3 条八分之一"
    case .fourthVerticalEighth: "第 4 条八分之一"
    case .fifthVerticalEighth: "第 5 条八分之一"
    case .sixthVerticalEighth: "第 6 条八分之一"
    case .seventhVerticalEighth: "第 7 条八分之一"
    case .lastVerticalEighth: "第 8 条八分之一"
    case .firstVerticalSixth: "第 1 条六分之一"
    case .secondVerticalSixth: "第 2 条六分之一"
    case .thirdVerticalSixth: "第 3 条六分之一"
    case .fourthVerticalSixth: "第 4 条六分之一"
    case .fifthVerticalSixth: "第 5 条六分之一"
    case .lastVerticalSixth: "第 6 条六分之一"
    }
  }

  /// 所属操作组，细分网格按区域数量归组。
  var group: String {
    if rawValue.hasPrefix("display") || self == .nextDisplay || self == .previousDisplay {
      return "显示器"
    }
    if Self.multiple.contains(self) { return "多个窗口" }
    if let region = unitRect {
      let cells = Int((1 / (region.width * region.height)).rounded())
      if cells >= 6 { return "细分网格" }
      return "分屏布局"
    }
    return "尺寸与位置"
  }

  /// 批量操作和重叠窗口切换需要读取同一屏幕的窗口集合。
  static let multiple: Set<Self> = [
    .reverseAll, .tileAll, .cascadeAll, .cascadeActiveApp,
    .tileActiveApp, .tileRows, .tileColumns, .cycleStackedWindows, .cycleStackedWindowsBackward,
  ]

  /// 归一化区域，x、y、宽、高均为屏幕可用区域的比例。
  var unitRect: CGRect? {
    switch self {
    case .leftHalf: CGRect(x: 0, y: 0, width: 0.5, height: 1)
    case .rightHalf: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
    case .topHalf: CGRect(x: 0, y: 0, width: 1, height: 0.5)
    case .bottomHalf: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
    case .topLeft: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
    case .topRight: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
    case .bottomLeft: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
    case .bottomRight: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
    case .firstThird: CGRect(x: 0, y: 0, width: 0.333333333333333, height: 1)
    case .centerThird: CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 1)
    case .lastThird: CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 1)
    case .firstTwoThirds: CGRect(x: 0, y: 0, width: 0.666666666666667, height: 1)
    case .lastTwoThirds: CGRect(x: 0.333333333333333, y: 0, width: 0.666666666666667, height: 1)
    case .centerTwoThirds: CGRect(x: 0.166666666666667, y: 0, width: 0.666666666666667, height: 1)
    case .centerHalf: CGRect(x: 0.25, y: 0, width: 0.5, height: 1)
    case .firstThreeFourths: CGRect(x: 0, y: 0, width: 0.75, height: 1)
    case .lastThreeFourths: CGRect(x: 0.25, y: 0, width: 0.75, height: 1)
    case .centerThreeFourths: CGRect(x: 0.125, y: 0, width: 0.75, height: 1)
    case .topVerticalThird: CGRect(x: 0, y: 0, width: 1, height: 0.333333333333333)
    case .middleVerticalThird:
      CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.333333333333333)
    case .bottomVerticalThird:
      CGRect(x: 0, y: 0.666666666666667, width: 1, height: 0.333333333333333)
    case .topVerticalTwoThirds: CGRect(x: 0, y: 0, width: 1, height: 0.666666666666667)
    case .bottomVerticalTwoThirds:
      CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.666666666666667)
    case .firstFourth: CGRect(x: 0, y: 0, width: 0.25, height: 1)
    case .secondFourth: CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
    case .thirdFourth: CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
    case .lastFourth: CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
    case .topLeftSixth: CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.5)
    case .topCenterSixth: CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.5)
    case .topRightSixth: CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.5)
    case .bottomLeftSixth: CGRect(x: 0, y: 0.5, width: 0.333333333333333, height: 0.5)
    case .bottomCenterSixth:
      CGRect(x: 0.333333333333333, y: 0.5, width: 0.333333333333333, height: 0.5)
    case .bottomRightSixth:
      CGRect(x: 0.666666666666667, y: 0.5, width: 0.333333333333333, height: 0.5)
    case .topLeftNinth: CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.333333333333333)
    case .topCenterNinth:
      CGRect(x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.333333333333333)
    case .topRightNinth:
      CGRect(x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.333333333333333)
    case .middleLeftNinth:
      CGRect(x: 0, y: 0.333333333333333, width: 0.333333333333333, height: 0.333333333333333)
    case .middleCenterNinth:
      CGRect(
        x: 0.333333333333333, y: 0.333333333333333, width: 0.333333333333333,
        height: 0.333333333333333)
    case .middleRightNinth:
      CGRect(
        x: 0.666666666666667, y: 0.333333333333333, width: 0.333333333333333,
        height: 0.333333333333333)
    case .bottomLeftNinth:
      CGRect(x: 0, y: 0.666666666666667, width: 0.333333333333333, height: 0.333333333333333)
    case .bottomCenterNinth:
      CGRect(
        x: 0.333333333333333, y: 0.666666666666667, width: 0.333333333333333,
        height: 0.333333333333333)
    case .bottomRightNinth:
      CGRect(
        x: 0.666666666666667, y: 0.666666666666667, width: 0.333333333333333,
        height: 0.333333333333333)
    case .topLeftEighth: CGRect(x: 0, y: 0, width: 0.25, height: 0.5)
    case .topCenterLeftEighth: CGRect(x: 0.25, y: 0, width: 0.25, height: 0.5)
    case .topCenterRightEighth: CGRect(x: 0.5, y: 0, width: 0.25, height: 0.5)
    case .topRightEighth: CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5)
    case .bottomLeftEighth: CGRect(x: 0, y: 0.5, width: 0.25, height: 0.5)
    case .bottomCenterLeftEighth: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.5)
    case .bottomCenterRightEighth: CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.5)
    case .bottomRightEighth: CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.5)
    case .topLeftTwelfth: CGRect(x: 0, y: 0, width: 0.25, height: 0.333333333333333)
    case .topCenterLeftTwelfth: CGRect(x: 0.25, y: 0, width: 0.25, height: 0.333333333333333)
    case .topCenterRightTwelfth: CGRect(x: 0.5, y: 0, width: 0.25, height: 0.333333333333333)
    case .topRightTwelfth: CGRect(x: 0.75, y: 0, width: 0.25, height: 0.333333333333333)
    case .middleLeftTwelfth:
      CGRect(x: 0, y: 0.333333333333333, width: 0.25, height: 0.333333333333333)
    case .middleCenterLeftTwelfth:
      CGRect(x: 0.25, y: 0.333333333333333, width: 0.25, height: 0.333333333333333)
    case .middleCenterRightTwelfth:
      CGRect(x: 0.5, y: 0.333333333333333, width: 0.25, height: 0.333333333333333)
    case .middleRightTwelfth:
      CGRect(x: 0.75, y: 0.333333333333333, width: 0.25, height: 0.333333333333333)
    case .bottomLeftTwelfth:
      CGRect(x: 0, y: 0.666666666666667, width: 0.25, height: 0.333333333333333)
    case .bottomCenterLeftTwelfth:
      CGRect(x: 0.25, y: 0.666666666666667, width: 0.25, height: 0.333333333333333)
    case .bottomCenterRightTwelfth:
      CGRect(x: 0.5, y: 0.666666666666667, width: 0.25, height: 0.333333333333333)
    case .bottomRightTwelfth:
      CGRect(x: 0.75, y: 0.666666666666667, width: 0.25, height: 0.333333333333333)
    case .topLeftSixteenth: CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
    case .topCenterLeftSixteenth: CGRect(x: 0.25, y: 0, width: 0.25, height: 0.25)
    case .topCenterRightSixteenth: CGRect(x: 0.5, y: 0, width: 0.25, height: 0.25)
    case .topRightSixteenth: CGRect(x: 0.75, y: 0, width: 0.25, height: 0.25)
    case .upperMiddleLeftSixteenth: CGRect(x: 0, y: 0.25, width: 0.25, height: 0.25)
    case .upperMiddleCenterLeftSixteenth: CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.25)
    case .upperMiddleCenterRightSixteenth: CGRect(x: 0.5, y: 0.25, width: 0.25, height: 0.25)
    case .upperMiddleRightSixteenth: CGRect(x: 0.75, y: 0.25, width: 0.25, height: 0.25)
    case .lowerMiddleLeftSixteenth: CGRect(x: 0, y: 0.5, width: 0.25, height: 0.25)
    case .lowerMiddleCenterLeftSixteenth: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25)
    case .lowerMiddleCenterRightSixteenth: CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
    case .lowerMiddleRightSixteenth: CGRect(x: 0.75, y: 0.5, width: 0.25, height: 0.25)
    case .bottomLeftSixteenth: CGRect(x: 0, y: 0.75, width: 0.25, height: 0.25)
    case .bottomCenterLeftSixteenth: CGRect(x: 0.25, y: 0.75, width: 0.25, height: 0.25)
    case .bottomCenterRightSixteenth: CGRect(x: 0.5, y: 0.75, width: 0.25, height: 0.25)
    case .bottomRightSixteenth: CGRect(x: 0.75, y: 0.75, width: 0.25, height: 0.25)
    case .topLeftThird: CGRect(x: 0, y: 0, width: 0.666666666666667, height: 0.5)
    case .topRightThird: CGRect(x: 0.333333333333333, y: 0, width: 0.666666666666667, height: 0.5)
    case .bottomLeftThird: CGRect(x: 0, y: 0.5, width: 0.666666666666667, height: 0.5)
    case .bottomRightThird:
      CGRect(x: 0.333333333333333, y: 0.5, width: 0.666666666666667, height: 0.5)
    case .firstVerticalEighth: CGRect(x: 0, y: 0, width: 0.125, height: 1)
    case .secondVerticalEighth: CGRect(x: 0.125, y: 0, width: 0.125, height: 1)
    case .thirdVerticalEighth: CGRect(x: 0.25, y: 0, width: 0.125, height: 1)
    case .fourthVerticalEighth: CGRect(x: 0.375, y: 0, width: 0.125, height: 1)
    case .fifthVerticalEighth: CGRect(x: 0.5, y: 0, width: 0.125, height: 1)
    case .sixthVerticalEighth: CGRect(x: 0.625, y: 0, width: 0.125, height: 1)
    case .seventhVerticalEighth: CGRect(x: 0.75, y: 0, width: 0.125, height: 1)
    case .lastVerticalEighth: CGRect(x: 0.875, y: 0, width: 0.125, height: 1)
    case .firstVerticalSixth: CGRect(x: 0, y: 0, width: 0.166666666666667, height: 1)
    case .secondVerticalSixth:
      CGRect(x: 0.166666666666667, y: 0, width: 0.166666666666667, height: 1)
    case .thirdVerticalSixth:
      CGRect(x: 0.333333333333333, y: 0, width: 0.166666666666667, height: 1)
    case .fourthVerticalSixth: CGRect(x: 0.5, y: 0, width: 0.166666666666667, height: 1)
    case .fifthVerticalSixth:
      CGRect(x: 0.666666666666667, y: 0, width: 0.166666666666667, height: 1)
    case .lastVerticalSixth: CGRect(x: 0.833333333333333, y: 0, width: 0.166666666666667, height: 1)
    default: nil
    }
  }

  /// 竖屏区域保持与对应动作的顺序一致，形状按屏幕长边适配。
  func unitRect(portrait: Bool) -> CGRect? {
    portrait ? Self.portraitRegions[self] ?? unitRect : unitRect
  }

  private static let portraitRegions: [Self: CGRect] = [
    .bottomCenterLeftEighth: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.25),
    .bottomCenterLeftTwelfth: CGRect(x: 0, y: 0.75, width: 0.333333333333333, height: 0.25),
    .bottomCenterRightEighth: CGRect(x: 0, y: 0.75, width: 0.5, height: 0.25),
    .bottomCenterRightTwelfth: CGRect(
      x: 0.333333333333333, y: 0.75, width: 0.333333333333333, height: 0.25),
    .bottomCenterSixth: CGRect(x: 0.5, y: 0.333333333333333, width: 0.5, height: 0.333333333333333),
    .bottomLeftEighth: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.25),
    .bottomLeftSixth: CGRect(x: 0, y: 0.666666666666667, width: 0.5, height: 0.333333333333333),
    .bottomLeftThird: CGRect(x: 0, y: 0.333333333333333, width: 0.5, height: 0.666666666666667),
    .bottomLeftTwelfth: CGRect(
      x: 0.666666666666667, y: 0.5, width: 0.333333333333333, height: 0.25),
    .bottomRightEighth: CGRect(x: 0.5, y: 0.75, width: 0.5, height: 0.25),
    .bottomRightSixth: CGRect(x: 0.5, y: 0.666666666666667, width: 0.5, height: 0.333333333333333),
    .bottomRightThird: CGRect(x: 0.5, y: 0.333333333333333, width: 0.5, height: 0.666666666666667),
    .bottomRightTwelfth: CGRect(
      x: 0.666666666666667, y: 0.75, width: 0.333333333333333, height: 0.25),
    .centerThird: CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.333333333333333),
    .centerThreeFourths: CGRect(x: 0, y: 0.125, width: 1, height: 0.75),
    .centerTwoThirds: CGRect(x: 0, y: 0.166666666666667, width: 1, height: 0.666666666666667),
    .fifthVerticalEighth: CGRect(x: 0, y: 0.5, width: 1, height: 0.125),
    .fifthVerticalSixth: CGRect(x: 0, y: 0.666666666666667, width: 1, height: 0.166666666666667),
    .firstFourth: CGRect(x: 0, y: 0, width: 1, height: 0.25),
    .firstThird: CGRect(x: 0, y: 0, width: 1, height: 0.333333333333333),
    .firstThreeFourths: CGRect(x: 0, y: 0, width: 1, height: 0.75),
    .firstTwoThirds: CGRect(x: 0, y: 0, width: 1, height: 0.666666666666667),
    .firstVerticalEighth: CGRect(x: 0, y: 0, width: 1, height: 0.125),
    .firstVerticalSixth: CGRect(x: 0, y: 0, width: 1, height: 0.166666666666667),
    .fourthVerticalEighth: CGRect(x: 0, y: 0.375, width: 1, height: 0.125),
    .fourthVerticalSixth: CGRect(x: 0, y: 0.5, width: 1, height: 0.166666666666667),
    .lastFourth: CGRect(x: 0, y: 0.75, width: 1, height: 0.25),
    .lastThird: CGRect(x: 0, y: 0.666666666666667, width: 1, height: 0.333333333333333),
    .lastThreeFourths: CGRect(x: 0, y: 0.25, width: 1, height: 0.75),
    .lastTwoThirds: CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.666666666666667),
    .lastVerticalEighth: CGRect(x: 0, y: 0.875, width: 1, height: 0.125),
    .lastVerticalSixth: CGRect(x: 0, y: 0.833333333333333, width: 1, height: 0.166666666666667),
    .middleCenterLeftTwelfth: CGRect(
      x: 0.666666666666667, y: 0.25, width: 0.333333333333333, height: 0.25),
    .middleCenterRightTwelfth: CGRect(x: 0, y: 0.5, width: 0.333333333333333, height: 0.25),
    .middleLeftTwelfth: CGRect(
      x: 0.333333333333333, y: 0.25, width: 0.333333333333333, height: 0.25),
    .middleRightTwelfth: CGRect(
      x: 0.333333333333333, y: 0.5, width: 0.333333333333333, height: 0.25),
    .secondFourth: CGRect(x: 0, y: 0.25, width: 1, height: 0.25),
    .secondVerticalEighth: CGRect(x: 0, y: 0.125, width: 1, height: 0.125),
    .secondVerticalSixth: CGRect(x: 0, y: 0.166666666666667, width: 1, height: 0.166666666666667),
    .seventhVerticalEighth: CGRect(x: 0, y: 0.75, width: 1, height: 0.125),
    .sixthVerticalEighth: CGRect(x: 0, y: 0.625, width: 1, height: 0.125),
    .thirdFourth: CGRect(x: 0, y: 0.5, width: 1, height: 0.25),
    .thirdVerticalEighth: CGRect(x: 0, y: 0.25, width: 1, height: 0.125),
    .thirdVerticalSixth: CGRect(x: 0, y: 0.333333333333333, width: 1, height: 0.166666666666667),
    .topCenterLeftEighth: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.25),
    .topCenterLeftTwelfth: CGRect(
      x: 0.333333333333333, y: 0, width: 0.333333333333333, height: 0.25),
    .topCenterRightEighth: CGRect(x: 0, y: 0.25, width: 0.5, height: 0.25),
    .topCenterRightTwelfth: CGRect(
      x: 0.666666666666667, y: 0, width: 0.333333333333333, height: 0.25),
    .topCenterSixth: CGRect(x: 0, y: 0.333333333333333, width: 0.5, height: 0.333333333333333),
    .topLeftEighth: CGRect(x: 0, y: 0, width: 0.5, height: 0.25),
    .topLeftSixth: CGRect(x: 0, y: 0, width: 0.5, height: 0.333333333333333),
    .topLeftThird: CGRect(x: 0, y: 0, width: 0.5, height: 0.666666666666667),
    .topLeftTwelfth: CGRect(x: 0, y: 0, width: 0.333333333333333, height: 0.25),
    .topRightEighth: CGRect(x: 0.5, y: 0.25, width: 0.5, height: 0.25),
    .topRightSixth: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.333333333333333),
    .topRightThird: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.666666666666667),
    .topRightTwelfth: CGRect(x: 0, y: 0.25, width: 0.333333333333333, height: 0.25),
    .centerHalf: CGRect(x: 0, y: 0.25, width: 1, height: 0.5),
  ]

  /// 沿用本机 Rectangle 0.64 所选的备用预设，后加的细分操作默认不占键。
  @MainActor var defaultHotKey: HotKey? {
    let modifiers = controlKey | optionKey
    return switch self {
    case .leftHalf: HotKey(keyCode: kVK_LeftArrow, modifiers: modifiers)
    case .rightHalf: HotKey(keyCode: kVK_RightArrow, modifiers: modifiers)
    case .topHalf: HotKey(keyCode: kVK_UpArrow, modifiers: modifiers)
    case .bottomHalf: HotKey(keyCode: kVK_DownArrow, modifiers: modifiers)
    case .topLeft: HotKey(keyCode: kVK_ANSI_U, modifiers: modifiers)
    case .topRight: HotKey(keyCode: kVK_ANSI_I, modifiers: modifiers)
    case .bottomLeft: HotKey(keyCode: kVK_ANSI_J, modifiers: modifiers)
    case .bottomRight: HotKey(keyCode: kVK_ANSI_K, modifiers: modifiers)
    case .maximize: HotKey(keyCode: kVK_Return, modifiers: modifiers)
    case .larger: HotKey(keyCode: kVK_ANSI_Equal, modifiers: modifiers)
    case .smaller: HotKey(keyCode: kVK_ANSI_Minus, modifiers: modifiers)
    case .center: HotKey(keyCode: kVK_ANSI_C, modifiers: modifiers)
    case .restore: HotKey(keyCode: kVK_Delete, modifiers: modifiers)
    case .firstThird: HotKey(keyCode: kVK_ANSI_D, modifiers: modifiers)
    case .firstTwoThirds: HotKey(keyCode: kVK_ANSI_E, modifiers: modifiers)
    case .centerThird: HotKey(keyCode: kVK_ANSI_F, modifiers: modifiers)
    case .lastTwoThirds: HotKey(keyCode: kVK_ANSI_T, modifiers: modifiers)
    case .lastThird: HotKey(keyCode: kVK_ANSI_G, modifiers: modifiers)
    case .maximizeHeight: HotKey(keyCode: kVK_UpArrow, modifiers: modifiers | shiftKey)
    case .previousDisplay: HotKey(keyCode: kVK_LeftArrow, modifiers: modifiers | cmdKey)
    case .nextDisplay: HotKey(keyCode: kVK_RightArrow, modifiers: modifiers | cmdKey)
    default: nil
    }
  }
}
