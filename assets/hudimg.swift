// 메뉴바용 합성 이미지 렌더러
//
// SwiftBar는 한 줄에 이미지 하나만 받는다.
// Claude 로고 + 5시간/주간, Codex 로고 + 주간을 한 PNG로 합성한다.
//
// 사용: hudimg <claude5h> <claude주간> <codex주간> <stale 0|1>
//   값은 정수 % 또는 음수(=데이터 없음 -> "–")
//   --probe              계산된 폭(pt)만 출력
//   --logo <이름> <pt>   드롭다운 헤더용 단독 로고
//
// ── 왜 밝은 색 + 검은 외곽선인가 ────────────────────────────────────
// 메뉴바 배경은 하나가 아니다: 어두운바 / 밝은바 / 눌림 하이라이트 / 뒤비치는 창.
// 채움색 하나로 넷을 다 버티는 색은 없다(후보 전부 실측 최소대비 1.0~1.7).
//   #4FE080 -> 어두움 8.85 · 터미널 4.88 · 눌림 3.01 · 밝음 1.58
//   검정    -> 밝음 19.43 · 사진 6.32 · 눌림 4.09 · 어두움 1.39
// 둘이 정확히 반대로 움직인다. 겹치면 어떤 배경에서도 한쪽이 살아남는다.
// 그래서 단색(template)으로 도망가지 않고 색을 유지한 채 읽히게 만든다.
//
// 외곽선은 strokeWidth 가 아니라 8방향 오프셋으로 그린다.
// strokeWidth 는 경로 중앙에 걸려 안쪽까지 먹는다 -> 작은 숫자의 속구멍(8,9,0)이
// 메워져 뭉갠다. 바깥으로만 번지게 하면 글리프 두께가 그대로 남는다(로고도 같은 방식).
//
// @2x 로 그리고 rep.size 를 절반으로 잡아 PNG 에 144dpi 를 심는다.
// 이렇게 해야 NSImage 가 픽셀을 포인트로 오해하지 않는다(레티나에서 2배로 커지는 문제).

import Cocoa

_ = NSApplication.shared

let args = CommandLine.arguments
func arg(_ i: Int) -> String { i < args.count ? args[i] : "" }

let probe = args.contains("--probe")
let stale = arg(4) == "1"

// 에셋은 바이너리 옆. 환경변수로 덮어쓸 수 있다.
let assetDir: URL = {
    if let e = ProcessInfo.processInfo.environment["TOKENHUD_ASSETS"] {
        return URL(fileURLWithPath: e)
    }
    return URL(fileURLWithPath: args[0]).deletingLastPathComponent()
}()

func hex(_ s: String) -> NSColor {
    var v: UInt64 = 0
    Scanner(string: s.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green:   CGFloat((v >> 8) & 0xFF) / 255,
                   blue:    CGFloat(v & 0xFF) / 255,
                   alpha: 1)
}

// 브랜드색. 민트(#10A37F)는 눌림 하이라이트에서 대비 1.10 까지 떨어져 빨강으로 교체했다.
let claudeBrand = hex(ProcessInfo.processInfo.environment["TOKENHUD_CLAUDE_COLOR"] ?? "#E8875F")
let codexBrand  = hex(ProcessInfo.processInfo.environment["TOKENHUD_CODEX_COLOR"] ?? "#FF5247")

// 상태색은 어두운 배경 기준으로 밝게 잡는다. 밝은 배경은 외곽선이 받친다.
// (예전 #34C759/#FF9500/#FF3B30 은 어두운바에서도 6.8/6.9/4.3 밖에 안 나왔다)
let gray = hex("#B4B4BA")
func statusColor(_ pct: Int) -> NSColor {
    if pct < 0   { return gray }
    if pct >= 90 { return hex("#FF6B61") }
    if pct >= 70 { return hex("#FFB340") }
    return hex("#4FE080")
}

func pctValue(_ s: String) -> Int { Int(s) ?? -1 }
func pctText(_ v: Int) -> String { v < 0 ? "–" : String(v) }

let c5 = pctValue(arg(1)), c7 = pctValue(arg(2)), x7 = pctValue(arg(3))

// 외곽선이 바깥으로 번지는 거리. 폰트 크기에 비례시킨다.
// 고정값으로 두면 작은 주간 숫자에서 상대적으로 두꺼워져 속구멍(8,9,0)이 메워진다.
// 12pt 에서 0.45pt 가 상한선이었다 -> 그 비율(0.0375)을 유지한다.
func edgeOffset(_ f: NSFont) -> CGFloat { f.pointSize * 0.0375 }

// ── 단독 로고 모드 ────────────────────────────────────────────────────
// 드롭다운 헤더용. `hudimg --logo claude [pt]` -> base64 PNG.
// 값이 안 변하므로 호출부에서 파일로 캐싱해 쓴다.
if let li = args.firstIndex(of: "--logo"), li + 1 < args.count {
    let name = args[li + 1]
    let pt = CGFloat(Double(li + 2 < args.count ? args[li + 2] : "") ?? 12)
    let brand = (name == "claude") ? claudeBrand : codexBrand
    guard let src = NSImage(contentsOf: assetDir.appendingPathComponent("\(name)@2x.png")),
          let bmp = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(pt * 2), pixelsHigh: Int(pt * 2),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { exit(2) }
    bmp.size = NSSize(width: pt, height: pt)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bmp)
    NSGraphicsContext.current?.imageInterpolation = .high
    let r = NSRect(x: 0, y: 0, width: pt, height: pt)
    src.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
    brand.set()
    r.fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bmp.representation(using: .png, properties: [:]) else { exit(3) }
    print(png.base64EncodedString())
    exit(0)
}

// ── 레이아웃 ──────────────────────────────────────────────────────────
let logoPt: CGFloat = 14        // 로고 한 변
let gapLogoNum: CGFloat = 3     // 로고-숫자
let gapSeg: CGFloat = 1         // Claude 숫자-슬래시
let gapPair: CGFloat = 8        // 클로드묶음-코덱스묶음
let padX: CGFloat = 1.5         // 외곽선이 잘리지 않게 여백을 준다
let height: CGFloat = 18
let scale: CGFloat = 2

// 11.5pt semibold 는 메뉴바에서 안 읽혔다. bold 로 올리고 크기도 키운다.
// 12/10 이 실측 타협점 — 13/11 보다 5pt 좁은데 가독성 차이가 없었고,
// 11.5/9.5 는 주간 숫자가 다시 뭉갠다.
// 바가 좁으면 TOKENHUD_FONT 로 줄인다(주간은 비율 유지해 따라 내려간다).
let fontPt = CGFloat(Double(ProcessInfo.processInfo.environment["TOKENHUD_FONT"] ?? "") ?? 12)
let font    = NSFont.monospacedDigitSystemFont(ofSize: fontPt, weight: .bold)
// 주간은 보조 정보라 더 낮춰도 된다. 비율은 TOKENHUD_SUBRATIO 로 조절.
let subRatio = CGFloat(Double(ProcessInfo.processInfo.environment["TOKENHUD_SUBRATIO"] ?? "") ?? 0.72)
let subFont = NSFont.monospacedDigitSystemFont(ofSize: fontPt * subRatio, weight: .bold)

// 채움 글자와, 그 뒤에 깔 검은 글자를 같이 들고 다닌다.
// 폰트가 둘이라 그릴 때 폰트별로 베이스라인을 맞춰야 해서 폰트도 함께 보관한다.
struct Seg {
    let body: NSAttributedString
    let edge: NSAttributedString
    let font: NSFont
    var width: CGFloat { body.size().width }
}

func seg(_ text: String, _ color: NSColor, _ f: NSFont) -> Seg {
    Seg(body: NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color]),
        edge: NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor.black]),
        font: f)
}

// Claude는 5시간/주간, Codex는 주간 하나만 표시한다.
func pairSegs(_ five: Int, _ week: Int) -> [Seg] {
    [seg(pctText(five), statusColor(five), font),
     seg("/", gray, subFont),
     seg(pctText(week), statusColor(week), subFont)]
}
let cSegs = pairSegs(c5, c7)
let xSegs = [seg(pctText(x7), statusColor(x7), font)]

func segsWidth(_ segs: [Seg]) -> CGFloat {
    segs.reduce(0) { $0 + $1.width } + gapSeg * CGFloat(segs.count - 1)
}
let totalW = ceil(padX * 2 + logoPt + gapLogoNum + segsWidth(cSegs)
                  + gapPair + logoPt + gapLogoNum + segsWidth(xSegs))

if probe {
    print(String(format: "%.0f", totalW))
    exit(0)
}

// ── 로고 로드 & 착색 ──────────────────────────────────────────────────
// 색을 입힌 글리프 뒤에 검은 실루엣을 8방향으로 깔아 외곽선을 만든다.
// 숫자와 같은 이유 — 눌림/밝은 배경에서 색이 묻혀도 형태는 남는다.
func logo(_ name: String, _ color: NSColor) -> NSImage? {
    let u = assetDir.appendingPathComponent("\(name)@2x.png")
    guard let src = NSImage(contentsOf: u) else { return nil }
    let size = NSSize(width: logoPt, height: logoPt)

    // 알파 모양만 남기고 한 가지 색으로 칠한 글리프
    func tinted(_ c: NSColor) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(origin: .zero, size: size),
                 from: .zero, operation: .sourceOver, fraction: 1)
        c.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        img.unlockFocus()
        return img
    }

    let body = tinted(color)
    let edge = tinted(.black)

    // 외곽선 두께만큼 사방 여백을 두고 그린다.
    // 0.45 이상이면 OpenAI 매듭의 안쪽 구멍이 메워진다. 0.3 이 형태 유지 한계선.
    let o: CGFloat = 0.3
    let out = NSImage(size: NSSize(width: size.width + o * 2, height: size.height + o * 2))
    out.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    for dx in [-o, 0, o] {
        for dy in [-o, 0, o] {
            if dx == 0 && dy == 0 { continue }
            edge.draw(in: NSRect(x: o + dx, y: o + dy, width: size.width, height: size.height),
                      from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
    body.draw(in: NSRect(x: o, y: o, width: size.width, height: size.height),
              from: .zero, operation: .sourceOver, fraction: 1)
    out.unlockFocus()
    return out
}

guard let cLogo = logo("claude", claudeBrand),
      let xLogo = logo("openai", codexBrand) else {
    FileHandle.standardError.write("logo assets missing in \(assetDir.path)\n".data(using: .utf8)!)
    exit(2)
}

// ── 합성 ──────────────────────────────────────────────────────────────
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(totalW * scale),
                                 pixelsHigh: Int(height * scale),
                                 bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(3) }
// 픽셀은 2배지만 논리 크기는 절반 -> PNG 에 144dpi 로 기록된다
rep.size = NSSize(width: totalW, height: height)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

var x = padX
// 폰트가 둘이라 top 정렬로 찍으면 숫자 밑이 어긋난다. 베이스라인을 공유한다.
let baselineY = (height - font.ascender + font.descender) / 2 - font.descender

// 로고는 외곽선만큼 커져 있다. 레이아웃 전진값은 logoPt 로 유지하고,
// 그리기만 실제 크기로 해서 글리프가 눌리지 않게 한다.
func drawLogo(_ img: NSImage, at cx: CGFloat) {
    let s = img.size
    img.draw(in: NSRect(x: cx + (logoPt - s.width) / 2,
                        y: (height - s.height) / 2,
                        width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1)
}

func drawSegs(_ segs: [Seg]) {
    for (i, s) in segs.enumerated() {
        let p = NSPoint(x: x, y: baselineY + s.font.descender)
        let o = edgeOffset(s.font)
        for dx in [-o, 0, o] {
            for dy in [-o, 0, o] {
                if dx == 0 && dy == 0 { continue }
                s.edge.draw(at: NSPoint(x: p.x + dx, y: p.y + dy))
            }
        }
        s.body.draw(at: p)
        x += s.width
        if i < segs.count - 1 { x += gapSeg }
    }
}

drawLogo(cLogo, at: x)
x += logoPt + gapLogoNum
drawSegs(cSegs)
x += gapPair

drawLogo(xLogo, at: x)
x += logoPt + gapLogoNum
drawSegs(xSegs)

NSGraphicsContext.restoreGraphicsState()

// 캐시 폴백 중이면 전체를 흐리게 -> 한눈에 "지금 값 아님"이 보인다.
// 로고/숫자를 각각 흐리게 하면 겹친 외곽선까지 비쳐 지저분해진다 -> 다 그린 뒤 한 번만.
if stale {
    guard let faded = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: rep.pixelsWide,
                                       pixelsHigh: rep.pixelsHigh,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0) else { exit(4) }
    faded.size = rep.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: faded)
    NSImage(size: rep.size, flipped: false) { r in
        rep.draw(in: r); return true
    }.draw(in: NSRect(origin: .zero, size: rep.size),
           from: .zero, operation: .sourceOver, fraction: 0.55)
    NSGraphicsContext.restoreGraphicsState()
    if let png = faded.representation(using: .png, properties: [:]) {
        print(png.base64EncodedString()); exit(0)
    }
}

guard let png = rep.representation(using: .png, properties: [:]) else { exit(5) }
print(png.base64EncodedString())
