//  MacDuo — 把 MacBook 当成一台 iPhone Duo，做「内屏折叠」的效果
//
//  映射：
//    上盖（屏幕）= 左面板，你正在看的桌面就是它的内屏 —— macOS 自己在渲染，不重绘
//    下盖（键盘）= 右面板，有一块屏和一块背板
//    铰链       = MacBook 转轴 = 屏幕的下边缘
//
//  所以这个 App 只叠加「折叠时内屏上该出现的东西」：
//    1. 右面板绕屏幕下边缘转上来 —— 转角直接就是盖板角度，物理上自洽：
//       100° 时投影在屏幕外看不见，90° 侧立成一条线，往下一路扫上来盖住屏幕
//    2. 折痕高光：屏幕下边缘那条光
//    3. haze 眩光：越合越强（查看器原值 opacity = .34 - .24 x 开合度）
//    4. 遮蔽阴影：右面板压过来时投在内屏上的影，跟着它的投影边缘走
//
//  配色移植自 apple.com/iphone-duo 产品查看器的复刻版。
//  刻意没移植弹簧+磁铁模拟器：那是给鼠标拖拽造手感的，这里输入是真实铰链。
//  只保留 55ms 临界阻尼滤波，消掉传感器整数度数的台阶。

import Cocoa
import CoreImage
import CoreMedia
import IOKit.hid
import ScreenCaptureKit
import QuartzCore
import ServiceManagement

// MARK: - 小工具

func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double { min(hi, max(lo, v)) }
func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp((x - e0) / (e1 - e0)); return t * t * (3 - 2 * t)
}
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a).cgColor
}

// MARK: - 日志（写文件，unified log 在这台机器上读不出来）

enum Log {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MacDuo.log")
    }()

    static func write(_ msg: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        let line = "[\(df.string(from: Date()))] \(msg)\n"
        NSLog("MacDuo: %@", msg)
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - 语言（默认英文，菜单里可切中文）

enum Lang: String, CaseIterable {
    case en, zh
    var label: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        }
    }
    /// 默认英文；用户切过一次就记在 UserDefaults 里
    static var current: Lang =
        Lang(rawValue: UserDefaults.standard.string(forKey: "language") ?? "") ?? .en
}

/// UI 文案：L(英文, 中文)。日志和存盘用的标识符一律英文，不走这里。
func L(_ en: String, _ zh: String) -> String { Lang.current == .en ? en : zh }

// MARK: - 模糊效果

enum BlurStyle: String, CaseIterable {
    case defocus, frosted, liquidGlass
    var label: String {
        switch self {
        case .defocus:     return L("Lens defocus (gradient blur, default)", "镜头失焦（梯度虚化，默认）")
        case .frosted:     return L("Frosted glass (uniform blur)", "磨砂玻璃（整屏均匀变虚）")
        case .liquidGlass: return L("Liquid glass (iOS 26)", "液态玻璃（iOS 26）")
        }
    }
}

// MARK: - 盖板角度传感器 (HID UsagePage 0x20 / Usage 0x8A, Feature Report ID 1)

final class LidSensor {
    private let manager: IOHIDManager
    private let device: IOHIDDevice

    init?() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDPrimaryUsagePageKey: 0x20, kIOHIDPrimaryUsageKey: 0x8A]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let dev = devices.first,
              IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
        else { return nil }
        manager = mgr; device = dev
    }

    func angle() -> Double? {
        var buf = [UInt8](repeating: 0, count: 8); var len = buf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &buf, &len) == kIOReturnSuccess,
              len >= 3 else { return nil }
        return Double(Int(buf[1]) | (Int(buf[2]) << 8))
    }
}

// MARK: - 右面板那块屏的画面

enum Screenface {
    static func desktopImage(for screen: NSScreen, maxPixel: Int) -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    /// 居中 aspect-fill 裁切框（归一化，原点左上，配合 CALayer.contentsRect）
    static func fillRect(imageSize: CGSize, target: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, target.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let ia = imageSize.width / imageSize.height, ta = target.width / target.height
        if ia > ta { let f = ta / ia; return CGRect(x: (1 - f) / 2, y: 0, width: f, height: 1) }
        let f = ia / ta; return CGRect(x: 0, y: (1 - f) / 2, width: 1, height: f)
    }

    /// 取不到壁纸时的兜底：查看器那张程序化壁纸
    static func procedural(size: CGSize, scale: CGFloat) -> CGImage? {
        let pw = Int(size.width * scale), ph = Int(size.height * scale)
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let w = size.width, h = size.height
        ctx.setFillColor(rgb(0x08071A)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        radial(ctx, colors: [rgb(0xF0B87E), rgb(0xC56A44), rgb(0x7C3A54),
                             rgb(0x35235A), rgb(0x120F2C), rgb(0x08071A)],
               stops: [0, 0.18, 0.40, 0.64, 0.86, 1.0],
               cx: w * 0.5, cy: h * 0.18, rx: w * 1.30, ry: h * 0.92, extend: true)
        radial(ctx, colors: [rgb(0x12100F), rgb(0x12100F, 0)], stops: [0, 0.62],
               cx: w * 0.5, cy: h * 0.04, rx: w * 0.58, ry: h * 0.34, extend: false)
        return ctx.makeImage()
    }

    private static func radial(_ ctx: CGContext, colors: [CGColor], stops: [CGFloat],
                               cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, extend: Bool) {
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: stops) else { return }
        ctx.saveGState(); ctx.translateBy(x: cx, y: cy); ctx.scaleBy(x: rx, y: ry)
        ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                               options: extend ? [.drawsAfterEndLocation] : [])
        ctx.restoreGState()
    }
}


// MARK: - 真实桌面捕获（ScreenCaptureKit）

/// 只在 overlay 可见时开流；必须排除 MacDuo 自己的窗口，否则面板里套面板无限递归。
final class DesktopCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State: String {
        case idle, starting, running, denied
        var label: String {
            switch self {
            case .idle:     return L("off", "未启动")
            case .starting: return L("starting", "启动中")
            case .running:  return L("running", "运行中")
            case .denied:   return L("no permission", "无权限")
            }
        }
    }

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.by.macduo.capture")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private(set) var state: State = .idle
    /// 只要一帧：拿到就转成 CGImage 交出去，然后立刻停流
    var needsSnapshot = true
    var onSnapshot: ((CGImage) -> Void)?

    private var askedThisLaunch = false

    /// 明确重试（菜单里手动触发）才会清掉 denied
    func resetDenial() { if state == .denied { state = .idle } }

    func start(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) {
        guard state == .idle else { return }          // denied 不自动重试，否则每次合盖都弹窗

        // 先用 preflight 查真实 TCC 状态，它不会弹窗
        if !CGPreflightScreenCaptureAccess() {
            state = .denied
            if !askedThisLaunch {
                askedThisLaunch = true
                Log.write("screen recording not authorized — asking once this launch")
                CGRequestScreenCaptureAccess()
            } else {
                Log.write("screen recording still not authorized — not asking again this launch "
                          + "(relaunch the app after granting)")
            }
            return
        }

        state = .starting
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID })
                        ?? content.displays.first else { self.state = .idle; return }

                // 排除自己，否则捕到的画面里又有这块面板
                let me = content.applications.filter {
                    $0.bundleIdentifier == Bundle.main.bundleIdentifier
                }
                let filter = SCContentFilter(display: display,
                                             excludingApplications: me,
                                             exceptingWindows: [])

                let cfg = SCStreamConfiguration()
                cfg.width = pixelWidth
                cfg.height = pixelHeight
                cfg.pixelFormat = kCVPixelFormatType_32BGRA
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                cfg.queueDepth = 3
                cfg.showsCursor = false
                cfg.capturesAudio = false

                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await s.startCapture()
                self.stream = s
                self.state = .running
                Log.write("capture started \(pixelWidth)x\(pixelHeight), own windows excluded")
            } catch {
                self.state = .denied
                Log.write("SCStream failed: \(error.localizedDescription) — preflight was true, "
                          + "most likely the app was not relaunched after granting")
            }
        }
    }

    func stop() {
        guard let s = stream else {
            if state != .denied { state = .idle }     // denied 要保住，否则下次合盖又弹窗
            return
        }
        stream = nil
        state = .idle
        Task { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        guard needsSnapshot, outputType == .screen,
              let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // IOSurface 会被流回收，必须拷成 CGImage 才能冻住
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        needsSnapshot = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSnapshot?(cg)
            self.stop()                      // 一帧够了，别挂着录屏
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("capture interrupted: \(error.localizedDescription)")
        self.stream = nil
        state = .idle
    }
}

// MARK: - 模糊图生成

enum Blur {
    static let ctx = CIContext(options: [.useSoftwareRenderer: false])
    static let levelCount = 8

    private static func gauss(_ img: CIImage, _ r: CGFloat) -> CIImage {
        let f = CIFilter(name: "CIGaussianBlur")!
        f.setValue(img.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(r, forKey: kCIInputRadiusKey)
        return f.outputImage!
    }
    private static func toLinear(_ i: CIImage) -> CIImage {
        let f = CIFilter(name: "CISRGBToneCurveToLinear")!
        f.setValue(i, forKey: kCIInputImageKey); return f.outputImage!
    }
    private static func toSRGB(_ i: CIImage) -> CIImage {
        let f = CIFilter(name: "CILinearToSRGBToneCurve")!
        f.setValue(i, forKey: kCIInputImageKey); return f.outputImage!
    }

    /// 生成 levelCount 级模糊，半径线性递增。
    ///
    /// 两个关键决定：
    /// 1. **在线性光空间里模糊**。sRGB 空间的高斯会把白高光糊成灰团（亮度塌陷），
    ///    看着发闷；转到线性光再模糊，高光才会保持明亮并向外晕开，像真实镜头失焦。
    /// 2. **迭代生成**。高斯可叠加：r_i 由 r_{i-1} 再模糊 sqrt(r_i²-r_{i-1}²) 得到，
    ///    每步半径都很小，比每级从原图重新大半径模糊快一个量级。
    ///
    /// 输出矩形用 createCGImage(from:) 显式指定 —— clampedToExtent 产出的是无限延展的
    /// CIImage，交给 CALayer.filters 会因为拿不到边界而画到屏幕角落去。
    static func levels(_ src: CGImage, maxRadiusPx R: CGFloat, downscale d: CGFloat = 4) -> [CGImage] {
        let base = CIImage(cgImage: src).transformed(by: CGAffineTransform(scaleX: 1 / d, y: 1 / d))
        let rect = base.extent
        var work = toLinear(base)
        var out: [CGImage] = []
        var prev: CGFloat = 0
        for i in 1...levelCount {
            let target = R / d * CGFloat(i) / CGFloat(levelCount)
            work = gauss(work, sqrt(max(target * target - prev * prev, 0.01))).cropped(to: rect)
            prev = target
            guard let cg = ctx.createCGImage(toSRGB(work), from: rect) else { break }
            out.append(cg)
        }
        return out
    }

    /// 液态玻璃的板身背景。
    ///
    /// iOS 26 的液态玻璃**不是**一层半透明白纱压在背景上 —— 那样越叠越灰。它是把背景
    /// 「吸」进材质里：模糊之后饱和度反而更高、更亮，所以玻璃永远带着底下内容的颜色。
    /// 所以这里补的是一道 CIColorControls，而不是在上面盖一层白。
    ///
    /// 直接在 levels() 那 8 级上改材质，不再单独跑高斯 —— 玻璃和失焦要的半径是同一套，
    /// 重跑一遍冷启多花约 250ms。剩下的只是一个逐像素颜色矩阵，8 级一共几毫秒。
    /// 每级都做是因为玻璃的糊度要跟着开合度连续变，只留最强那级就没有过渡了。
    static func glassSkins(_ levels: [CGImage]) -> [CGImage] {
        levels.compactMap { level in
            let img = CIImage(cgImage: level)
            guard let cc = CIFilter(name: "CIColorControls") else { return nil }
            cc.setValue(img, forKey: kCIInputImageKey)
            cc.setValue(1.60, forKey: kCIInputSaturationKey)   // 吸底色
            cc.setValue(0.050, forKey: kCIInputBrightnessKey)  // 玻璃自己会亮一点
            cc.setValue(1.03, forKey: kCIInputContrastKey)
            guard let out = cc.outputImage else { return nil }
            return ctx.createCGImage(out, from: img.extent)
        }
    }

    /// 首次调用 CoreImage 要编译 kernel，冷启约 290ms。提前在后台空转一次。
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            guard let g = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let img = g.makeImage() else { return }
            _ = levels(img, maxRadiusPx: 16, downscale: 2)
            Log.write("CoreImage warm-up done")
        }
    }
}

// MARK: - 舞台：透明 overlay

/// 合盖瞬间冻一张全屏截图，然后沿铰链方向做梯度模糊。
/// 没有任何扫入 / 缩放动画 —— 一开始就是整屏。
final class Stage {
    private let window: NSWindow
    private let host = NSView()

    private let shot = CALayer()            // 冻结的全屏截图（清晰版）
    private var blurLayers: [CALayer] = []      // 8 级预渲染模糊，自下而上叠
    private var blurMasks: [CAGradientLayer] = []
    private let blurHost = CALayer()            // 装这 8 层，方便整体插到 shot 之上
    private let haze = CAGradientLayer()    // 内屏眩光
    private let crease = CAGradientLayer()  // 铰链那条边的折痕光
    private let dim = CALayer()             // 收尾的轻微压暗
    private let veil = CALayer()            // 磨砂那层奶白（只有 .frosted 用）

    // 液态玻璃：板身直接复用上面那 8 层（贴的是提饱和过的那套图），这里只装四条边的倒角
    private let glassHost = CALayer()
    private let glassSheen = CAGradientLayer()  // 板面斜向柔光
    private var bevelHosts: [CALayer] = []      // 四条屏幕边，每条一个（带渐隐 mask）
    private var bevelMasks: [CAGradientLayer] = []
    private var bevelClips: [[CALayer]] = []    // 每条边分 4 段逼近倒角曲线
    private var bevelImgs: [[CALayer]] = []
    private var bevelSpecs: [CAGradientLayer] = []

    private var blurImgs: [CGImage] = []        // 8 级模糊原图
    private var glassImgs: [CGImage] = []       // 同样 8 级，改过材质
    private var rimLevel = -1                   // 折射带当前贴的是第几级，变了才重贴

    let capture = DesktopCapture()

    /// true = 离铰链越远越虚（默认）；false = 反过来，铰链处最虚。
    /// 液态玻璃模式下同一个开关决定玻璃板从哪头扫过来。
    var blurStrongerFar = true

    var style: BlurStyle = .defocus {
        didSet {
            guard style != oldValue else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            applyStyleVisibility()
            CATransaction.commit()
        }
    }

    private(set) var visible = false
    private var laidOut = false
    private var hasShot = false
    private var hasBlur = false
    private var hasGlass = false
    private var lastFold: Double = 0
    private var lastFoldTime = Date()
    private var foldSpeed: Double = 0        // 平滑过的 |d(fold)/dt|，喂给玻璃的「液态」拉伸
    private var maxRadiusPx: CGFloat = 100
    private var screenW: CGFloat = 0, screenH: CGFloat = 0
    private var span: CGFloat = 0
    private var displayID: CGDirectDisplayID = 0
    private var pixelW = 0, pixelH = 0
    private var stopWork: DispatchWorkItem?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = host
        host.wantsLayer = true
        guard let root = host.layer else { return }
        root.addSublayer(shot)
        root.addSublayer(blurHost)
        root.addSublayer(veil)
        root.addSublayer(glassHost)
        root.addSublayer(haze)
        root.addSublayer(dim)
        root.addSublayer(crease)

        glassHost.addSublayer(glassSheen)
        for _ in Side.allCases {
            let host = CALayer()
            let mask = CAGradientLayer()
            host.mask = mask
            var clips: [CALayer] = [], imgs: [CALayer] = []
            for _ in 0..<Stage.bevelSegments {
                let clip = CALayer(); clip.masksToBounds = true
                let img = CALayer()
                img.contentsGravity = .resize
                img.magnificationFilter = .linear
                img.minificationFilter = .trilinear  // 最外段压缩两倍以上，不插值会出锯齿
                clip.addSublayer(img)
                host.addSublayer(clip)
                clips.append(clip); imgs.append(img)
            }
            let spec = CAGradientLayer()
            glassHost.addSublayer(host)
            glassHost.addSublayer(spec)
            bevelHosts.append(host); bevelMasks.append(mask)
            bevelClips.append(clips); bevelImgs.append(imgs)
            bevelSpecs.append(spec)
        }
        glassHost.isHidden = true

        capture.onSnapshot = { [weak self] image in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.shot.contents = image

            self.shot.opacity = 1
            self.hasShot = true
            CATransaction.commit()
            Log.write("froze full-screen grab \(image.width)x\(image.height)")

            // 8 级模糊 + 玻璃板身放后台算，算好再贴上去。两套都算：菜单随时能切效果，
            // 现算会在切换那一帧卡住。一共约 13.5MB，隐藏时一起摘掉。
            // 玻璃板身是最强那级模糊改的材质，所以几乎不额外要钱。
            let r = self.maxRadiusPx
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = Date()
                let imgs = Blur.levels(image, maxRadiusPx: r)
                let skins = Blur.glassSkins(imgs)
                DispatchQueue.main.async {
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    self.blurImgs = imgs
                    self.glassImgs = skins
                    self.hasBlur = imgs.count == Blur.levelCount
                    self.hasGlass = skins.count == Blur.levelCount
                    self.applyStyleVisibility()          // 按当前效果把对应那套贴上去
                    CATransaction.commit()
                    Log.write(String(format: "blur pyramid ready: %d levels + %d glass, %.0fms, max radius %.0fpx",
                                     imgs.count, skins.count,
                                     Date().timeIntervalSince(t0) * 1000, r))
                }
            }
        }
    }

    var builtinScreen: NSScreen? {
        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            if CGDisplayIsBuiltin(CGDirectDisplayID(num.uint32Value)) != 0 { return screen }
        }
        return NSScreen.screens.first
    }

    /// 梯度沿「铰链 → 远端」方向。铰链就是 MacBook 转轴 = 屏幕下边缘，所以恒为「下 → 上」。
    private let maskAxis: (start: CGPoint, end: CGPoint) =
        (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))

    /// 铰链那头保留的底噪虚化量 —— 保证 fold=1 时整块屏都是虚的，只是远端最重
    private let hingeFloor = 0.15

    /// 某点的连续模糊等级：p = 沿「铰链→远端」的归一化距离
    private func blurLevel(at p: Double, fold: Double) -> Double {
        fold * (hingeFloor + (1 - hingeFloor) * p) * Double(Blur.levelCount)
    }

    /// 第 i 层只在「局部等级 ≥ i」的地方完全露出，i-1 到 i 之间线性过渡。
    /// 相邻两级半径只差 1/8，交叉淡化看起来就是半径在连续变大，而不是清晰图和
    /// 模糊图叠在一起的重影。
    private func setMask(_ mask: CAGradientLayer, level i: Int, fold: Double) -> Bool {
        let axis = maskAxis                          // start = 铰链, end = 远端
        mask.startPoint = blurStrongerFar ? axis.start : axis.end
        mask.endPoint   = blurStrongerFar ? axis.end : axis.start

        func alpha(_ p: Double) -> Double { clamp(blurLevel(at: p, fold: fold) - Double(i - 1)) }
        let a0 = alpha(0), a1 = alpha(1)
        if a0 <= 0.001 && a1 <= 0.001 { return false }   // 这一级还没轮到

        // 解出 alpha 从 0 爬到 1 的那两个位置，做成 4 个停靠点的分段线性梯度
        func pFor(_ target: Double) -> Double {
            guard fold > 1e-4 else { return 2 }
            return ((target / (fold * Double(Blur.levelCount))) - hingeFloor) / (1 - hingeFloor)
        }
        let s1 = clamp(pFor(Double(i - 1))), s2 = clamp(pFor(Double(i)))
        mask.locations = [0, NSNumber(value: Float(s1)),
                          NSNumber(value: Float(max(s2, s1))), 1]
        mask.colors = [rgb(0xFFFFFF, CGFloat(a0)), rgb(0xFFFFFF, CGFloat(alpha(s1))),
                       rgb(0xFFFFFF, CGFloat(alpha(max(s2, s1)))), rgb(0xFFFFFF, CGFloat(a1))]
        return true
    }

    /// 磨砂：整屏一个虚化量，没有梯度 —— mask 两端同色即可
    /// 磨砂和液态玻璃这两块「材质」共用的进度曲线：`pow(fold, materialRamp)`。
    ///
    /// 指数要 **> 1（缓入）**。线性映射下开头十几度就糊到看不清了 —— 感知上的糊度对
    /// 半径是饱和的，过了约 20px 再加半径看着没区别，于是整段角度里只有前 15% 在动，
    /// 后面全程一个样。1.35 把可感知的变化摊到整个 99°→30° 上。
    private let materialRamp = 1.35

    private func setUniformMask(_ mask: CAGradientLayer, level i: Int, amount: Double) -> Bool {
        let a = clamp(amount * Double(Blur.levelCount) - Double(i - 1))
        if a <= 0.001 { return false }
        mask.startPoint = CGPoint(x: 0.5, y: 0); mask.endPoint = CGPoint(x: 0.5, y: 1)
        mask.locations = [0, 1]
        mask.colors = [rgb(0xFFFFFF, CGFloat(a)), rgb(0xFFFFFF, CGFloat(a))]
        return true
    }

    // MARK: 液态玻璃的几何
    //
    // 玻璃是**整屏**的一块板，不扫也不移 —— 板身就是上面那 8 层（贴提饱和的那套图），
    // 糊度跟开合度走。iOS 26 的身份全靠四条屏幕边上的倒角：越贴边，画面被挤压得越狠。
    // 屏幕外面没有内容可折射，所以取样方向反过来 —— 把里面的画面往边上挤：
    //
    //     S(u) = w · u^0.45     u = 从屏幕边往里的深度（0…1，单位 w）
    //
    // u^0.45 在 u→0 处斜率发散，正好是倒角贴边那一段的强压缩，到内端自然收成 1:1。
    // 单调递增，所以画面不会翻转；分 4 段仿射逼近，接缝处取样点连续，看不出缝。

    private enum Side: CaseIterable {
        case bottom, top, left, right
        var vertical: Bool { self == .bottom || self == .top }
    }

    /// 从某条屏幕边往里 [d0, d1] 的那条横贯带
    private func edgeBand(_ side: Side, _ d0: CGFloat, _ d1: CGFloat) -> CGRect {
        let lo = min(d0, d1), hi = max(d0, d1)
        switch side {
        case .bottom: return CGRect(x: 0, y: lo, width: screenW, height: hi - lo)
        case .top:    return CGRect(x: 0, y: screenH - hi, width: screenW, height: hi - lo)
        case .left:   return CGRect(x: lo, y: 0, width: hi - lo, height: screenH)
        case .right:  return CGRect(x: screenW - hi, y: 0, width: hi - lo, height: screenH)
        }
    }

    /// 把整张截图缩放定位，使屏幕上的 src 区域正好落到 dst 区域。src 比 dst 宽就是压缩。
    /// 不用 contentsRect：那个的 y 轴原点在 macOS 上有歧义，直接摆 frame 没有。
    /// sheet = 这张图当前铺开的矩形（玻璃比屏幕大一圈，所以不能写死成全屏）
    private func lensFrame(src: CGRect, dst: CGRect, vertical: Bool, sheet: CGRect) -> CGRect {
        if vertical {
            guard src.height > 0.5 else { return dst }
            let k = dst.height / src.height
            return CGRect(x: sheet.minX, y: dst.minY - (src.minY - sheet.minY) * k,
                          width: sheet.width, height: sheet.height * k)
        }
        guard src.width > 0.5 else { return dst }
        let k = dst.width / src.width
        return CGRect(x: dst.minX - (src.minX - sheet.minX) * k, y: sheet.minY,
                      width: sheet.width * k, height: sheet.height)
    }

    /// 梯度方向：起点落在屏幕边那一侧
    private func edgeAxis(_ side: Side) -> (start: CGPoint, end: CGPoint) {
        switch side {
        case .bottom: return (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1))
        case .top:    return (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        case .left:   return (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        case .right:  return (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        }
    }

    /// 三种效果共用那 8 层堆叠，区别只在贴哪套图、铺多大、用什么 mask、额外叠什么
    private func applyStyleVisibility() {
        let glass = style == .liquidGlass
        glassHost.isHidden = !glass
        let imgs = glass ? glassImgs : blurImgs
        let rect = glass ? glassSheet : CGRect(x: 0, y: 0, width: screenW, height: screenH)
        for (i, l) in blurLayers.enumerated() {
            l.contents = i < imgs.count ? imgs[i] : nil
            l.frame = rect
            l.mask?.frame = l.bounds
        }
    }

    func layout() {
        guard let screen = builtinScreen else { return }
        window.setFrame(screen.frame, display: false)
        let w = screen.frame.width, h = screen.frame.height
        let sf = screen.backingScaleFactor
        screenW = w; screenH = h
        span = h
        pixelW = Int(w * sf); pixelH = Int(h * sf)
        if let num = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            displayID = CGDirectDisplayID(num.uint32Value)
        }

        CATransaction.begin(); CATransaction.setDisableActions(true)
        let b = CGRect(x: 0, y: 0, width: w, height: h)
        host.layer?.frame = b

        // 清晰版：整屏，没有任何缩放或扫入
        shot.frame = b
        shot.contentsGravity = .resize
        shot.opacity = 0

        // 8 级预渲染模糊自下而上叠在清晰版上，各自用梯度 mask 控制露出范围。
        // 模糊图是 1/4 分辨率，放大用线性插值 —— 反正已经糊了，看不出来。
        maxRadiusPx = span * sf * 0.05
        blurHost.frame = b
        blurHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        blurLayers = []; blurMasks = []
        for _ in 0..<Blur.levelCount {
            let l = CALayer()
            l.frame = b
            l.contentsGravity = .resize
            l.magnificationFilter = .linear
            l.masksToBounds = true
            l.opacity = 0
            let m = CAGradientLayer()
            m.frame = b
            l.mask = m
            blurHost.addSublayer(l)
            blurLayers.append(l); blurMasks.append(m)
        }

        // 液态玻璃：板面柔光铺满全屏，四条边的倒角每帧算 frame
        glassHost.frame = b
        glassSheen.frame = b
        glassSheen.startPoint = CGPoint(x: 0, y: 1)
        glassSheen.endPoint = CGPoint(x: 1, y: 0)
        glassSheen.colors = [rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0.02), rgb(0xFFFFFF, 0.096)]
        glassSheen.locations = [0, 0.55, 1]
        for i in bevelHosts.indices {
            bevelHosts[i].frame = .zero
            bevelMasks[i].frame = .zero
            bevelSpecs[i].frame = .zero
        }
        applyStyleVisibility()

        haze.frame = b
        haze.colors = [NSColor(srgbRed: 190/255, green: 205/255, blue: 1, alpha: 0.30).cgColor,
                       NSColor(srgbRed: 1, green: 190/255, blue: 140/255, alpha: 0.10).cgColor,
                       rgb(0xFFFFFF, 0)]
        haze.locations = [0, 0.55, 1]
        haze.startPoint = CGPoint(x: 0.53, y: 1)
        haze.endPoint = CGPoint(x: 0.47, y: 0)
        haze.opacity = 0

        dim.frame = b
        dim.backgroundColor = NSColor.black.cgColor
        dim.opacity = 0

        // 磨砂玻璃是有厚度的材质，不是失焦：糊之外还得有一层冷调的奶白，
        // 不然「整屏均匀变虚」和失焦梯度在实际角度下读起来是同一个东西
        veil.frame = b
        veil.backgroundColor = NSColor(srgbRed: 240/255, green: 246/255, blue: 1, alpha: 1).cgColor
        veil.opacity = 0

        // 折痕：骑在铰链那条边上，只看得见靠屏幕这半条
        let cw = span * 0.025
        crease.frame = CGRect(x: 0, y: -cw / 2, width: w, height: cw)
        crease.startPoint = CGPoint(x: 0.5, y: 0); crease.endPoint = CGPoint(x: 0.5, y: 1)
        crease.colors = [rgb(0xFFFFFF, 0), rgb(0xFFFFFF, 0.14),
                         rgb(0x000000, 0.30), rgb(0xFFFFFF, 0.16), rgb(0xFFFFFF, 0)]
        crease.locations = [0, 0.28, 0.5, 0.72, 1]
        crease.opacity = 0

        applyContentsScale(host.layer!, sf)
        CATransaction.commit()
    }

    private func applyContentsScale(_ layer: CALayer, _ sf: CGFloat) {
        layer.contentsScale = sf
        layer.mask?.contentsScale = sf          // mask 不在 sublayers 里，漏了会有带状
        layer.sublayers?.forEach { applyContentsScale($0, sf) }
    }

    func invalidateLayout() { laidOut = false }

    /// 盖板刚开始动就先把流拉起来，免得真要显示时截图还没到
    func prime() {
        if !laidOut { layout(); laidOut = true }
        guard !hasShot, capture.state == .idle else { return }
        capture.needsSnapshot = true
        capture.start(displayID: displayID, pixelWidth: pixelW, pixelHeight: pixelH)
    }

    func show() {
        stopWork?.cancel(); stopWork = nil
        if !laidOut { layout(); laidOut = true }
        if !visible { window.orderFrontRegardless(); visible = true }
        if !hasShot && capture.state == .idle {
            capture.needsSnapshot = true
            capture.start(displayID: displayID, pixelWidth: pixelW, pixelHeight: pixelH)
        }
    }

    func hide() {
        guard visible else { return }
        window.orderOut(nil); visible = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shot.opacity = 0
        CATransaction.commit()
        // 下次合盖要重新截一张
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.capture.stop()
            self.hasShot = false
            self.hasBlur = false
            self.hasGlass = false
            self.capture.needsSnapshot = true
            // 截图 23.7MB + 模糊 12MB + 玻璃 12MB，不摘掉会一直挂在图层上
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.shot.contents = nil
            self.blurLayers.forEach { $0.contents = nil; $0.opacity = 0 }
            self.bevelImgs.forEach { $0.forEach { $0.contents = nil } }
            self.rimLevel = -1
            self.blurImgs = []; self.glassImgs = []
            CATransaction.commit()
        }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 倒角：段数、宽度（占屏幕短边）、取样指数 S(u)=w·u^squeeze
    private static let bevelSegments = 4
    private let bevelDepth = 0.045
    private let bevelSqueeze = 0.45
    /// 玻璃板比截图大出去多少（每边，占该方向的比例）。
    /// 倒角是把画面往边上挤的，1:1 铺的话最外圈会被挤出一条「空边」，看着像没铺满全屏；
    /// 板子铺大一圈，挤掉的那部分正好由溢出的内容补上，视觉上才是满屏。
    private let glassOverfill = 0.025

    /// 液态玻璃模式下，那 8 层材质实际铺开的矩形（比屏幕大一圈，超出部分被窗口裁掉）
    private var glassSheet: CGRect {
        CGRect(x: 0, y: 0, width: screenW, height: screenH)
            .insetBy(dx: -screenW * CGFloat(glassOverfill), dy: -screenH * CGFloat(glassOverfill))
    }

    /// fold: 0 = 展平, 1 = 完全合拢
    func render(fold: Double) {
        guard span > 0, hasShot else { return }

        let now = Date()
        let dt = max(1e-3, min(0.25, now.timeIntervalSince(lastFoldTime)))
        let raw = abs(fold - lastFold) / dt
        lastFold = fold; lastFoldTime = now
        foldSpeed += (raw - foldSpeed) * min(1, dt / 0.08)   // 别让折射带跟着采样抖

        CATransaction.begin(); CATransaction.setDisableActions(true)

        // 材质类效果（磨砂 / 液态玻璃）走缓入曲线，整段角度里都在变
        let amount = pow(fold, materialRamp)
        if hasBlur {
            for i in 1...Blur.levelCount {
                let mask = blurMasks[i - 1]
                let on = style == .defocus ? setMask(mask, level: i, fold: fold)
                                           : setUniformMask(mask, level: i, amount: amount)
                blurLayers[i - 1].opacity = on ? 1 : 0
            }
        }
        if style == .liquidGlass { renderGlassEdges(amount: amount) }

        veil.opacity = style == .frosted ? Float(amount * 0.26) : 0
        haze.opacity = Float(fold * fold * 0.12)
        crease.opacity = Float(0.10 + 0.45 * fold)
        // 玻璃和磨砂自己都会提亮，再压 0.20 会打架
        dim.opacity = Float(smoothstep(0.55, 1, fold) * (style == .defocus ? 0.20 : 0.10))

        CATransaction.commit()
    }

    /// 液态玻璃的四条边。
    ///
    /// 板身不在这里 —— 它就是上面那 8 层，只是贴的图被 `Blur.glassSkins` 提过饱和。
    /// 这里只画 iOS 26 那个材质真正的身份特征，全部长在**屏幕边**上、原地不动：
    ///   倒角折射 —— 越贴边画面被挤压得越狠，玻璃的厚度就是从这里读出来的
    ///   边缘高光 —— 贴边一条细亮线，冷白往里转暖白，就是色散
    /// 「液态」体现在开合越快，倒角越厚、高光越亮 —— 材质被拉扯的感觉。
    /// 每帧只改 frame 和梯度停靠点，没有任何每帧的 CoreImage。
    private func renderGlassEdges(amount: Double) {
        guard hasGlass, screenW > 0, screenH > 0 else { glassHost.isHidden = true; return }
        glassHost.isHidden = false

        let stretch = clamp(foldSpeed / 2.5)
        // 边缘比板身早一点出来：糊还没上来时先有一圈玻璃边，才知道盖了东西上去
        glassHost.opacity = Float(clamp(amount * 1.6))
        let sheet = glassSheet

        // 折射带贴的图必须**也是玻璃**，只是比板身浅几级。
        // 之前贴的是清晰版截图，等于屏幕最外圈套了一圈没上材质的锐利内容 —— 玻璃看着就铺不到边。
        // 但也不能直接用板身那级：全糊了就看不出画面被挤压，折射也就白做了。
        let rimIdx = min(max(Int(amount * Double(Blur.levelCount) * 0.25), 0), glassImgs.count - 1)
        if rimIdx != rimLevel, rimIdx >= 0, rimIdx < glassImgs.count {
            rimLevel = rimIdx
            let img = glassImgs[rimIdx]
            bevelImgs.forEach { $0.forEach { $0.contents = img } }
        }
        let w = min(screenW, screenH) * CGFloat(bevelDepth)
              * CGFloat(0.55 + 0.45 * amount) * CGFloat(1 + 0.3 * stretch)
        let n = Double(Stage.bevelSegments)
        let spec = CGFloat(0.72 * (1 + 0.25 * stretch))

        for (k, side) in Side.allCases.enumerated() {
            let band = edgeBand(side, 0, w)
            let host = bevelHosts[k], mask = bevelMasks[k]
            host.frame = band
            mask.frame = host.bounds
            let axis = edgeAxis(side)
            mask.startPoint = axis.start; mask.endPoint = axis.end
            mask.locations = [0, 0.30, 1]
            mask.colors = [rgb(0xFFFFFF, 1), rgb(0xFFFFFF, 0.75), rgb(0xFFFFFF, 0)]

            for j in 0..<Stage.bevelSegments {
                let u0 = Double(j) / n, u1 = Double(j + 1) / n
                let dst = edgeBand(side, w * CGFloat(u0), w * CGFloat(u1))
                let src = edgeBand(side, w * CGFloat(pow(u0, bevelSqueeze)),
                                         w * CGFloat(pow(u1, bevelSqueeze)))
                let clip = bevelClips[k][j], img = bevelImgs[k][j]
                clip.isHidden = dst.width < 0.5 || dst.height < 0.5
                guard !clip.isHidden else { continue }
                clip.frame = CGRect(x: dst.minX - band.minX, y: dst.minY - band.minY,
                                    width: dst.width, height: dst.height)
                let f = lensFrame(src: src, dst: dst, vertical: side.vertical, sheet: sheet)
                img.frame = CGRect(x: f.minX - dst.minX, y: f.minY - dst.minY,
                                   width: f.width, height: f.height)
            }

            let sp = bevelSpecs[k]
            sp.frame = band
            sp.startPoint = axis.start; sp.endPoint = axis.end
            sp.locations = [0, 0.05, 0.16, 0.55]
            sp.colors = [NSColor(srgbRed: 216/255, green: 240/255, blue: 1,
                                 alpha: spec).cgColor,               // 冷白
                         rgb(0xFFFFFF, spec * 0.34),
                         NSColor(srgbRed: 1, green: 232/255, blue: 205/255,
                                 alpha: spec * 0.08).cgColor,        // 暖白，色散的另一头
                         rgb(0xFFFFFF, 0)]
        }
    }
}

// MARK: - 主控

final class Controller: NSObject, NSMenuDelegate {
    private let sensor: LidSensor
    private let stage = Stage()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var timer: DispatchSourceTimer?

    private var enabled = true
    private var fastMode = false
    private var menuOpen = false
    private var failures = 0
    private var lastTick = Date()

    // 过渡区间：startAngle 开始虚化，endAngle 到最深，两头都可在菜单里设
    private var startAngle: Double = 99
    private var endAngle: Double = 30
    private var rawAngle: Double = 99
    private var angle: Double = 99               // 平滑后的角度
    private var fold: Double = 0                 // 0 展平 / 1 合拢，慢半拍
    private var demoStart: Date?

    private let angleTau = 0.055                 // 只消传感器整数度台阶
    private let foldTau = 0.12                   // 查看器的「画面慢半拍」

    // 标题在 buildMenu 里按当前语言填，切语言时整个菜单重建
    private let angleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let startItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let endItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleEnabled), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "", action: #selector(toggleLogin), keyEquivalent: "")
    private let captureItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var styleItems: [NSMenuItem] = []
    private var langItems: [NSMenuItem] = []
    private let flipItem = NSMenuItem(title: "", action: #selector(toggleFlip), keyEquivalent: "")

    init(sensor: LidSensor) {
        self.sensor = sensor
        super.init()
        if UserDefaults.standard.object(forKey: "startAngle") != nil {
            startAngle = UserDefaults.standard.double(forKey: "startAngle")
        }
        if UserDefaults.standard.object(forKey: "endAngle") != nil {
            endAngle = UserDefaults.standard.double(forKey: "endAngle")
        }
        if startAngle - endAngle < 5 { startAngle = 99; endAngle = 30 }
        if UserDefaults.standard.object(forKey: "blurStrongerFar") != nil {
            stage.blurStrongerFar = UserDefaults.standard.bool(forKey: "blurStrongerFar")
        }
        if let raw = UserDefaults.standard.string(forKey: "blurStyle"),
           let s = BlurStyle(rawValue: raw) { stage.style = s }
        buildMenu()
        Blur.warmUp()
        Log.write("launch — screen recording preflight = \(CGPreflightScreenCaptureAccess())"
                  + String(format: ", language = %@, blur = %@, range %.0f° → %.0f°",
                           Lang.current.rawValue, stage.style.rawValue, startAngle, endAngle))
        if ProcessInfo.processInfo.environment["MACDUO_DEMO"] != nil { demoStart = Date() }
        if let a = sensor.angle() { rawAngle = a; angle = a }
        schedule(fast: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func buildMenu() {
        // 切语言时重建：先把复用的那几个 item 从旧菜单上摘下来，NSMenuItem 不能同时挂两个菜单
        statusItem.menu?.removeAllItems()
        statusItem.menu = nil
        styleItems.removeAll(); langItems.removeAll()

        statusItem.button?.image = NSImage(systemSymbolName: "macbook", accessibilityDescription: "MacDuo")
            ?? NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "MacDuo")
        let menu = NSMenu(); menu.delegate = self
        toggleItem.title = L("Enabled", "启用")
        toggleItem.target = self; toggleItem.state = enabled ? .on : .off
        loginItem.title = L("Launch at Login", "开机自启")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        flipItem.title = L("Blurrier away from the hinge (lens defocus only; uncheck to invert)",
                           "离铰链越远越虚（只影响镜头失焦，取消=反过来）")
        flipItem.state = stage.blurStrongerFar ? .on : .off
        updateTitles()
        angleItem.isEnabled = false; startItem.isEnabled = false; endItem.isEnabled = false
        menu.addItem(toggleItem); menu.addItem(.separator())
        menu.addItem(angleItem); menu.addItem(startItem); menu.addItem(endItem)
        let setStart = NSMenuItem(title: L("Set Current Angle as Start", "把当前角度设为起始角"),
                                  action: #selector(setStartAngle), keyEquivalent: "")
        setStart.target = self; menu.addItem(setStart)
        let setEnd = NSMenuItem(title: L("Set Current Angle as End", "把当前角度设为结束角"),
                                action: #selector(setEndAngle), keyEquivalent: "")
        setEnd.target = self; menu.addItem(setEnd)
        let reset = NSMenuItem(title: L("Reset to 99° → 30°", "恢复默认 99° → 30°"),
                               action: #selector(resetAngles), keyEquivalent: "")
        reset.target = self; menu.addItem(reset)
        menu.addItem(.separator())
        let styleItem = NSMenuItem(title: L("Blur Style", "模糊效果"), action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for st in BlurStyle.allCases {
            let it = NSMenuItem(title: st.label, action: #selector(pickStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = st.rawValue
            it.state = (st == stage.style) ? .on : .off
            styleMenu.addItem(it)
            styleItems.append(it)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        flipItem.target = self
        menu.addItem(flipItem)
        menu.addItem(.separator())
        captureItem.isEnabled = false
        menu.addItem(captureItem)
        let openPrefs = NSMenuItem(title: L("Open System Settings → Screen Recording",
                                            "打开系统设置 → 屏幕录制"),
                                   action: #selector(openScreenRecordingPrefs), keyEquivalent: "")
        openPrefs.target = self
        menu.addItem(openPrefs)
        let relaunch = NSMenuItem(title: L("Relaunch MacDuo After Granting", "授权后点这里重启 MacDuo"),
                                  action: #selector(relaunchApp), keyEquivalent: "")
        relaunch.target = self
        menu.addItem(relaunch)
        menu.addItem(.separator())
        let preview = NSMenuItem(title: L("Play Preview Once", "播放一次预览"),
                                 action: #selector(playPreview), keyEquivalent: "")
        preview.target = self; menu.addItem(preview)
        let langItem = NSMenuItem(title: L("Language", "语言"), action: nil, keyEquivalent: "")
        let langMenu = NSMenu()
        for l in Lang.allCases {
            let it = NSMenuItem(title: l.label, action: #selector(pickLang(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = l.rawValue
            it.state = (l == Lang.current) ? .on : .off
            langMenu.addItem(it)
            langItems.append(it)
        }
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(loginItem)
        let quit = NSMenuItem(title: L("Quit MacDuo", "退出 MacDuo"),
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
    }

    /// 角度 / 捕获状态这几条标题是动态的，菜单打开时每帧刷，切语言时也刷一次
    private func updateTitles() {
        angleItem.title = String(format: L("Lid angle %.0f°", "当前角度 %.0f°"), rawAngle)
        startItem.title = String(format: L("Start %.0f° (blur begins)", "起始角 %.0f°（开始虚化）"),
                                 startAngle)
        endItem.title = String(format: L("End %.0f° (fully blurred)", "结束角 %.0f°（虚化到最深）"),
                               endAngle)
        captureItem.title = L("Desktop capture: ", "桌面捕获 ") + stage.capture.state.label
    }

    private func schedule(fast: Bool) {
        fastMode = fast
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: fast ? .milliseconds(8) : .milliseconds(66),
                   leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        let now = Date()
        let dt = min(0.1, now.timeIntervalSince(lastTick))
        lastTick = now

        var targetAngle: Double

        if let t0 = demoStart {
            let e = now.timeIntervalSince(t0), total = 5.0
            if e >= total { demoStart = nil; schedule(fast: false); return }
            let lo = max(endAngle - 10, 0), hi = startAngle
            if e < 2.0 { targetAngle = hi - (hi - lo) * e / 2.0 }
            else if e < 3.0 { targetAngle = lo }
            else { targetAngle = lo + (hi - lo) * (e - 3.0) / 2.0 }
            targetAngle = clamp(targetAngle, lo, hi)
            if !fastMode { schedule(fast: true) }
        } else {
            guard let a = sensor.angle() else {
                failures += 1
                if failures > 5 { stage.hide() }
                return
            }
            failures = 0
            let delta = abs(a - rawAngle)
            rawAngle = a
            if delta > 0.5 && !fastMode { schedule(fast: true) }
            if delta < 0.2 && fastMode && abs(angle - a) < 0.2 { schedule(fast: false) }
            guard enabled else { stage.hide(); return }
            targetAngle = a
        }

        angle += (targetAngle - angle) * (1 - exp(-dt / angleTau))

        // 99° -> 30° 线性映射到 0 -> 1，两头各自可调
        let foldTargetValue = clamp((startAngle - angle) / max(startAngle - endAngle, 1))
        fold += (foldTargetValue - fold) * (1 - exp(-dt / foldTau))

        // 盖板刚开始动就先把捕获拉起来，免得真要显示时截图还没到
        if angle < startAngle + 15 && targetAngle < angle { stage.prime() }

        if angle >= startAngle - 0.05 && targetAngle >= startAngle - 0.05 {
            stage.hide()
        } else {
            stage.show()
            stage.render(fold: fold)
        }

        if menuOpen { updateTitles() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc private func screensChanged() { stage.invalidateLayout(); if stage.visible { stage.layout() } }
    @objc private func openScreenRecordingPrefs() {
        stage.capture.resetDenial()
        if let u = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(u)
        }
    }

    @objc private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let st = BlurStyle(rawValue: raw) else { return }
        stage.style = st
        UserDefaults.standard.set(raw, forKey: "blurStyle")
        for it in styleItems { it.state = (it === sender) ? .on : .off }
        Log.write("blur style → \(st.rawValue)")
    }

    @objc private func pickLang(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let l = Lang(rawValue: raw), l != Lang.current else { return }
        Lang.current = l
        UserDefaults.standard.set(raw, forKey: "language")
        Log.write("language → \(raw)")
        // 菜单还在跟踪中，等这一轮结束再换掉整个菜单
        DispatchQueue.main.async { [weak self] in self?.buildMenu() }
    }

    @objc private func toggleFlip() {
        stage.blurStrongerFar.toggle()
        flipItem.state = stage.blurStrongerFar ? .on : .off
        UserDefaults.standard.set(stage.blurStrongerFar, forKey: "blurStrongerFar")
    }
    @objc private func toggleEnabled() {
        enabled.toggle(); toggleItem.state = enabled ? .on : .off
        if !enabled { stage.hide() }
    }
    @objc private func setStartAngle() {
        startAngle = min(180, max(endAngle + 5, rawAngle))
        UserDefaults.standard.set(startAngle, forKey: "startAngle")
        Log.write(String(format: "start angle set to %.0f°", startAngle))
    }
    @objc private func setEndAngle() {
        endAngle = max(0, min(startAngle - 5, rawAngle))
        UserDefaults.standard.set(endAngle, forKey: "endAngle")
        Log.write(String(format: "end angle set to %.0f°", endAngle))
    }
    @objc private func resetAngles() {
        startAngle = 99; endAngle = 30
        UserDefaults.standard.set(startAngle, forKey: "startAngle")
        UserDefaults.standard.set(endAngle, forKey: "endAngle")
    }
    @objc private func playPreview() { demoStart = Date(); schedule(fast: true) }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister(); loginItem.state = .off
            } else {
                try SMAppService.mainApp.register(); loginItem.state = .on
            }
        } catch { NSLog("MacDuo: launch-at-login toggle failed %@", error.localizedDescription) }
    }
    @objc private func quit() { stage.hide(); NSApp.terminate(nil) }
}

// MARK: - 自拍验证
//
//   MACDUO_SHOOT=<目录> open build/MacDuo.app
//
// 往 Stage 里灌一张**合成桌面**（不是真桌面），三种效果各渲几张，用 ScreenCaptureKit
// 只抓自己那一个窗口存 PNG，然后退出。
//
// 为什么非得这么绕：CALayer.render(in:) 不支持 mask，CARenderer 在这台机器上渲出来是空的，
// CGWindowListCreateImage 已经从 SDK 里撤了。而这套效果的正确性**全在 mask 和嵌套裁剪上**，
// 靠 CG 复刻一遍合成只能验自己的算法，验不了 Core Animation 真实的行为。
// SCContentFilter(desktopIndependentWindow:) 抓的是窗口服务器合成完的结果，跟眼睛看到的一致。
// 抓自己的窗口用的是 App 自己那份录屏授权，所以必须走 LaunchServices 启动（open），
// 直接跑 Contents/MacOS 里的二进制拿不到授权。

func testDesktop(_ w: CGFloat, _ h: CGFloat, _ sf: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(w*sf), height: Int(h*sf), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: sf, y: sf)
    var drew = false
    for name in ["Big Sur Aerial", "Big Sur Coastline"] {
        let u = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails/\(name).heic")
        if let s = CGImageSourceCreateWithURL(u as CFURL, nil),
           let i = CGImageSourceCreateThumbnailAtIndex(s, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 4000] as CFDictionary) {
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h)); drew = true; break
        }
    }
    if !drew { ctx.setFillColor(rgb(0x1B3B6F)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
    func win(_ r: CGRect, _ tint: CGColor) {
        ctx.setFillColor(tint); ctx.fill(r)
        ctx.setFillColor(rgb(0xFFFFFF, 0.12)); ctx.fill(CGRect(x: r.minX, y: r.maxY-40, width: r.width, height: 40))
        for row in 0..<16 {
            let y = r.maxY - 70 - CGFloat(row)*26
            guard y > r.minY + 16 else { break }
            ctx.setFillColor(rgb(0xFFFFFF, row % 4 == 0 ? 0.85 : 0.42))
            ctx.fill(CGRect(x: r.minX+22, y: y, width: r.width*(row % 3 == 2 ? 0.42 : 0.78),
                            height: row % 4 == 0 ? 11 : 8))
        }
    }
    win(CGRect(x: w*0.06, y: h*0.15, width: w*0.42, height: h*0.63), rgb(0x14161C, 0.94))
    win(CGRect(x: w*0.42, y: h*0.09, width: w*0.50, height: h*0.71), rgb(0x1E2430, 0.92))
    ctx.setFillColor(rgb(0xFFFFFF, 0.18)); ctx.fill(CGRect(x: w/2-260, y: 14, width: 520, height: 64))
    for i in 0..<8 {
        ctx.setFillColor(rgb([0x4A90D9,0xE8743B,0x50C878,0xD94A6A,0xF3C244,0x8A6FD1,0x3FBFBF,0xEDEDED][i]))
        ctx.fill(CGRect(x: w/2-248+CGFloat(i)*62, y: 22, width: 48, height: 48))
    }
    return ctx.makeImage()!
}

extension Stage {
    /// private 成员在同一文件的 extension 里可以访问 —— 所以验的是真身
    var testWindowID: CGWindowID { CGWindowID(window.windowNumber) }
    var testPixels: (Int, Int) { (Int(screenW * 2), Int(screenH * 2)) }

    func testPrepare(style s: BlurStyle, fold: Double) {
        style = s
        lastFold = fold - 0.024          // 造一点前沿速度，液态拉伸才有值
        lastFoldTime = Date().addingTimeInterval(-0.02)
        render(fold: fold)
        window.orderFrontRegardless()
        CATransaction.flush()
    }
    func testDone() { window.orderOut(nil) }

    @MainActor func testInject() async -> Bool {
        layout()
        capture.onSnapshot?(testDesktop(screenW, screenH, 2))
        let deadline = Date().addingTimeInterval(8)
        while !(hasBlur && hasGlass) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        Log.write("hasShot=\(hasShot) hasBlur=\(hasBlur) hasGlass=\(hasGlass)")
        return hasBlur && hasGlass
    }
}

@MainActor func shoot(_ stage: Stage, _ style: BlurStyle, _ fold: Double, _ dir: String) async {
    stage.testPrepare(style: style, fold: fold)
    try? await Task.sleep(nanoseconds: 300_000_000)
    defer { stage.testDone() }
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let win = content.windows.first(where: { $0.windowID == stage.testWindowID }) else {
            Log.write("own window not found \(stage.testWindowID)"); return
        }
        let cfg = SCStreamConfiguration()
        (cfg.width, cfg.height) = stage.testPixels
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: win), configuration: cfg)
        let path = "\(dir)/real-\(style.rawValue)-\(Int(fold*100)).png"
        guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                        "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
        Log.write("wrote \(path) \(img.width)x\(img.height)")
    } catch {
        Log.write("window grab failed: \(error.localizedDescription)")
    }
}

// MARK: - 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// MACDUO_SHOOT=<目录>：不跑正常流程，只出验证图（见上面「自拍验证」）
if let shootDir = ProcessInfo.processInfo.environment["MACDUO_SHOOT"] {
    let stage = Stage()
    Task { @MainActor in
        guard await stage.testInject() else { Log.write("SHOOT: inject failed"); exit(1) }
        for (st, f) in [(BlurStyle.defocus, 0.45),
                        (.frosted, 0.15), (.frosted, 0.45), (.frosted, 0.85),
                        (.liquidGlass, 0.15), (.liquidGlass, 0.45), (.liquidGlass, 0.85)] {
            await shoot(stage, st, f, shootDir)
        }
        Log.write("SHOOT: done")
        exit(0)
    }
    app.run()
    exit(0)
}

guard let sensor = LidSensor() else {
    let alert = NSAlert()
    alert.messageText = L("Lid angle sensor not found", "找不到盖板角度传感器")
    alert.informativeText = L("This Mac has no Lid Angle Sensor (HID 0x20/0x8A), so MacDuo cannot run.",
                              "这台 Mac 没有 Lid Angle Sensor (HID 0x20/0x8A)，MacDuo 无法运行。")
    alert.runModal(); exit(1)
}
let controller = Controller(sensor: sensor)
_ = controller
app.run()
