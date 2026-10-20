import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// MS Paint-level image editor: pen, eraser, shapes, bucket fill, text, rectangle select with
/// copy / cut / paste / move / crop, undo. Works on a flat bitmap (at most 2048 px on a side).
struct PaintView: View {
    @State private var doc = PaintDoc()
    @State private var photoItem: PhotosPickerItem?
    @State private var importing = false
    @State private var result: URL?
    @State private var textAt: CGPoint?
    @State private var textInput = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let result {
                    ResultCard(url: result).padding(.horizontal).padding(.bottom, 6)
                }
                PaintCanvas(doc: doc) { point in
                    textInput = ""
                    textAt = point
                }
                .padding(.horizontal, 8)
                // Always takes its space so the canvas doesn't jump when a selection appears
                selectionBar
                    .opacity(doc.selection != nil || doc.floating != nil ? 1 : 0)
                    .disabled(doc.selection == nil && doc.floating == nil)
                toolbar
            }
            .bentoScreen()
            .navigationTitle("paint")
            .navigationBarTitleDisplayMode(.inline)
            .bentoCloseButton()
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { doc.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!doc.canUndo)
                    Button { doc.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!doc.canRedo)
                    Menu {
                        Button("New blank canvas", systemImage: "doc") { doc.newBlank(); result = nil }
                        Button("Open from Files", systemImage: "folder") { importing = true }
                        Button("Paste", systemImage: "doc.on.clipboard") { doc.paste() }
                        Divider()
                        Button("Export", systemImage: "square.and.arrow.down") { result = doc.export() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .principal) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Media", systemImage: "photo").font(.subheadline.bold())
                    }
                }
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        doc.open(image); result = nil
                    }
                    photoItem = nil
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { picked in
                guard case .success(let url) = picked else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { doc.open(image); result = nil }
            }
            .alert("Text", isPresented: Binding(get: { textAt != nil }, set: { if !$0 { textAt = nil } })) {
                TextField("Type something", text: $textInput)
                Button("Add") { if let p = textAt, !textInput.isEmpty { doc.stampText(textInput, at: p) }; textAt = nil }
                Button("Cancel", role: .cancel) { textAt = nil }
            }
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 8) {
            if doc.floating != nil {
                Button("Done", systemImage: "checkmark") { doc.commitFloating() }
                Button("Delete", systemImage: "trash", role: .destructive) { doc.discardFloating() }
            } else {
                Button("Copy", systemImage: "doc.on.doc") { doc.copySelection() }
                Button("Cut", systemImage: "scissors") { doc.cutSelection() }
                Button("Delete", systemImage: "trash", role: .destructive) { doc.deleteSelection() }
                Button("Crop", systemImage: "crop") { doc.cropToSelection() }
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.bold())
        .buttonStyle(.bordered)
        .tint(.primary)
        .padding(.top, 8)
    }

    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                    ForEach(PaintDoc.Tool.allCases) { tool in
                        Button {
                            doc.tool = tool
                        } label: {
                            Image(systemName: tool.symbol)
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 40)
                                .background(doc.tool == tool ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(doc.tool == tool ? Color(.systemBackground) : .primary)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary, lineWidth: 1.2))
                        }
                        .accessibilityLabel(tool.rawValue)
                    }
            }
            .padding(.horizontal, 12)
            HStack(spacing: 6) {
                ForEach(PaintDoc.palette, id: \.self) { c in
                    Circle()
                        .fill(Color(c))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary, lineWidth: doc.color == c ? 3 : 1))
                        .onTapGesture { doc.color = c }
                }
                ColorPicker("", selection: Binding(get: { Color(doc.color) }, set: { doc.color = UIColor($0) }))
                    .labelsHidden()
            }
            HStack {
                Image(systemName: "circle.fill").font(.system(size: 6))
                Slider(value: $doc.size, in: 1...40)
                Image(systemName: "circle.fill").font(.system(size: 18))
            }
            .tint(.primary)
            .padding(.horizontal)
        }
        .padding(.vertical, 10)
    }
}

// MARK: - Canvas

/// Shows the bitmap fitted to the space, plus live previews; turns touches into image-pixel coordinates
private struct PaintCanvas: View {
    let doc: PaintDoc
    let askText: (CGPoint) -> Void
    @State private var stroke: [CGPoint] = []
    @State private var dragStart: CGPoint?
    @State private var dragNow: CGPoint?
    @State private var movingFrom: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = doc.image.size
            let scale = min(geo.size.width / size.width, geo.size.height / size.height)
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            let toImage: (CGPoint) -> CGPoint = { p in CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }

            ZStack(alignment: .topLeading) {
                Image(uiImage: doc.image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: shown.width, height: shown.height)
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.4), lineWidth: 1))
                    .offset(x: origin.x, y: origin.y)
                Canvas { ctx, _ in
                    ctx.translateBy(x: origin.x, y: origin.y)
                    ctx.scaleBy(x: scale, y: scale)
                    let color = Color(doc.tool == .eraser ? .white : doc.color)
                    let width = doc.brushPixels(viewScale: scale)
                    if stroke.count > 1 {
                        var path = Path(); path.addLines(stroke)
                        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    }
                    if let a = dragStart, let b = dragNow, let shape = PaintDoc.shapePath(doc.tool, a, b) {
                        ctx.stroke(shape, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                    if let f = doc.floating {
                        ctx.draw(Image(uiImage: f.image), in: CGRect(origin: f.origin, size: f.image.size))
                    }
                    if let r = doc.floating.map({ CGRect(origin: $0.origin, size: $0.image.size) }) ?? doc.selection {
                        ctx.stroke(Path(r), with: .color(.black), style: StrokeStyle(lineWidth: 1.5 / scale, dash: [6 / scale, 4 / scale]))
                        ctx.stroke(Path(r), with: .color(.white), style: StrokeStyle(lineWidth: 1.5 / scale, dash: [6 / scale, 4 / scale], dashPhase: 5 / scale))
                    }
                }
                .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let p = toImage(g.location)
                        switch doc.tool {
                        case .pen, .eraser:
                            stroke.append(p)
                        case .line, .rectangle, .ellipse:
                            if dragStart == nil { dragStart = p }
                            dragNow = p
                        case .select:
                            if movingFrom == nil, dragStart == nil, doc.hitsSelection(p) {
                                doc.liftSelection()
                                movingFrom = p
                            }
                            if let from = movingFrom {
                                doc.moveFloating(by: CGPoint(x: p.x - from.x, y: p.y - from.y))
                                movingFrom = p
                            } else {
                                if dragStart == nil { dragStart = p; doc.commitFloating(); doc.selection = nil }
                                dragNow = p
                                doc.selection = PaintDoc.rect(dragStart!, p).intersection(CGRect(origin: .zero, size: doc.image.size))
                            }
                        case .fill, .text:
                            dragNow = p
                        }
                    }
                    .onEnded { g in
                        let p = toImage(g.location)
                        switch doc.tool {
                        case .pen, .eraser:
                            if stroke.count == 1 { stroke.append(CGPoint(x: p.x + 0.1, y: p.y)) }
                            doc.commitStroke(stroke, scale: scale)
                        case .line, .rectangle, .ellipse:
                            if let a = dragStart { doc.commitShape(a, p, scale: scale) }
                        case .select:
                            if let sel = doc.selection, sel.width < 2 || sel.height < 2 { doc.selection = nil }
                        case .fill:
                            doc.fill(at: p)
                        case .text:
                            askText(p)
                        }
                        stroke = []; dragStart = nil; dragNow = nil; movingFrom = nil
                    }
            )
        }
    }
}

// MARK: - Document

@MainActor
@Observable
final class PaintDoc {
    enum Tool: String, CaseIterable, Identifiable {
        case pen = "Pen", eraser = "Eraser", line = "Line", rectangle = "Rectangle", ellipse = "Ellipse"
        case fill = "Fill", text = "Text", select = "Select"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pen: "pencil.tip"
            case .eraser: "eraser"
            case .line: "line.diagonal"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .fill: "drop.fill"
            case .text: "textformat"
            case .select: "rectangle.dashed"
            }
        }
    }

    struct Floating {
        var image: UIImage
        var origin: CGPoint
    }

    /// The classic Paint swatches
    static let palette: [UIColor] = [.black, .white, .systemGray, .systemRed, .systemOrange, .systemYellow,
                                     .systemGreen, .systemTeal, .systemBlue, .systemPurple, .systemPink, .brown]

    private(set) var image: UIImage
    var tool: Tool = .pen
    var color: UIColor = .black
    /// On-screen brush size in points
    var size: Double = 6
    var selection: CGRect?
    private(set) var floating: Floating?
    private var clipboard: UIImage?
    private var undoStack: [UIImage] = []
    private var redoStack: [UIImage] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init() { image = Self.blank(CGSize(width: 1080, height: 1350)) }

    // MARK: Files

    func newBlank() { push(); image = Self.blank(CGSize(width: 1080, height: 1350)); selection = nil; floating = nil }

    func open(_ picked: UIImage) {
        push()
        let longest = max(picked.size.width, picked.size.height)
        let scale = min(1, 2048 / longest)
        let size = CGSize(width: (picked.size.width * scale).rounded(), height: (picked.size.height * scale).rounded())
        image = render(size) { _ in picked.draw(in: CGRect(origin: .zero, size: size)) }
        selection = nil; floating = nil
    }

    func export() -> URL? {
        commitFloating()
        guard let data = image.pngData() else { return nil }
        let url = VideoIO.output(named: nil, suffix: nil, ext: "png")
            .deletingLastPathComponent().appendingPathComponent("paint-\(Int(Date().timeIntervalSince1970)).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: Drawing

    func brushPixels(viewScale: CGFloat) -> CGFloat { size / max(viewScale, 0.01) }

    func commitStroke(_ points: [CGPoint], scale: CGFloat) {
        guard points.count > 1 else { return }
        let color = tool == .eraser ? UIColor.white : color
        let width = brushPixels(viewScale: scale)
        edit { ctx in
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(width)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addLines(between: points); ctx.strokePath()
        }
    }

    func commitShape(_ a: CGPoint, _ b: CGPoint, scale: CGFloat) {
        guard let path = Self.shapePath(tool, a, b)?.cgPath else { return }
        let width = brushPixels(viewScale: scale)
        edit { ctx in
            ctx.setStrokeColor(self.color.cgColor); ctx.setLineWidth(width); ctx.setLineCap(.round)
            ctx.addPath(path); ctx.strokePath()
        }
    }

    func stampText(_ text: String, at p: CGPoint) {
        let font = UIFont.systemFont(ofSize: max(14, size * 6 * image.size.width / 1080), weight: .semibold)
        edit { _ in
            (text as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: self.color])
        }
    }

    /// Paint bucket: fills the connected region of similar color
    func fill(at p: CGPoint) {
        guard let cg = image.cgImage else { return }
        let w = cg.width, h = cg.height
        let x0 = Int(p.x), y0 = Int(p.y)
        guard (0..<w).contains(x0), (0..<h).contains(y0) else { return }
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
        defer { bytes.deallocate() }
        guard let ctx = CGContext(data: bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let fillColor = [UInt8(r * 255), UInt8(g * 255), UInt8(b * 255), 255]
        let start = (y0 * w + x0) * 4
        let target = (0..<4).map { Int(bytes[start + $0]) }
        if target[0] == Int(fillColor[0]), target[1] == Int(fillColor[1]), target[2] == Int(fillColor[2]) { return }
        func matches(_ i: Int) -> Bool {
            abs(Int(bytes[i]) - target[0]) + abs(Int(bytes[i + 1]) - target[1]) + abs(Int(bytes[i + 2]) - target[2]) < 48
        }
        var stack = [(x0, y0)]
        while let (x, y) = stack.popLast() {
            var left = x
            while left > 0, matches((y * w + left - 1) * 4) { left -= 1 }
            var right = x
            while right < w - 1, matches((y * w + right + 1) * 4) { right += 1 }
            for xi in left...right {
                let i = (y * w + xi) * 4
                bytes[i] = fillColor[0]; bytes[i + 1] = fillColor[1]; bytes[i + 2] = fillColor[2]; bytes[i + 3] = 255
                if y > 0, matches(((y - 1) * w + xi) * 4) { stack.append((xi, y - 1)) }
                if y < h - 1, matches(((y + 1) * w + xi) * 4) { stack.append((xi, y + 1)) }
            }
        }
        guard let out = ctx.makeImage() else { return }
        push()
        image = UIImage(cgImage: out)
    }

    // MARK: Selection

    func hitsSelection(_ p: CGPoint) -> Bool {
        if let f = floating { return CGRect(origin: f.origin, size: f.image.size).contains(p) }
        return selection?.contains(p) ?? false
    }

    private func crop(_ r: CGRect) -> UIImage? {
        guard let cg = image.cgImage?.cropping(to: r.integral) else { return nil }
        return UIImage(cgImage: cg)
    }

    func copySelection() {
        guard let sel = selection, let piece = crop(sel) else { return }
        clipboard = piece
        UIPasteboard.general.image = piece
    }

    func cutSelection() { copySelection(); deleteSelection() }

    func deleteSelection() {
        guard let sel = selection else { return }
        edit { ctx in ctx.setFillColor(UIColor.white.cgColor); ctx.fill(sel) }
        selection = nil
    }

    func cropToSelection() {
        guard let sel = selection, let piece = crop(sel) else { return }
        push()
        image = render(piece.size) { _ in piece.draw(at: .zero) }
        selection = nil
    }

    /// Picks the selected pixels up so they can be dragged (leaves white behind, like Paint)
    func liftSelection() {
        guard floating == nil, let sel = selection, let piece = crop(sel) else { return }
        edit { ctx in ctx.setFillColor(UIColor.white.cgColor); ctx.fill(sel) }
        floating = Floating(image: piece, origin: sel.integral.origin)
        selection = nil
    }

    func moveFloating(by d: CGPoint) {
        floating?.origin.x += d.x
        floating?.origin.y += d.y
    }

    func commitFloating() {
        guard let f = floating else { return }
        floating = nil
        edit { _ in f.image.draw(at: f.origin) }
        selection = CGRect(origin: f.origin, size: f.image.size).intersection(CGRect(origin: .zero, size: image.size))
    }

    func discardFloating() { floating = nil }

    /// Pastes Bento's clipboard, or an image copied in another app, as a movable piece
    func paste() {
        commitFloating()
        guard var piece = UIPasteboard.general.image ?? clipboard else { return }
        let fit = min(1, image.size.width / piece.size.width, image.size.height / piece.size.height)
        if fit < 1 {
            let s = CGSize(width: piece.size.width * fit, height: piece.size.height * fit)
            piece = render(s) { _ in piece.draw(in: CGRect(origin: .zero, size: s)) }
        }
        tool = .select
        floating = Floating(image: piece, origin: CGPoint(x: (image.size.width - piece.size.width) / 2,
                                                          y: (image.size.height - piece.size.height) / 2))
    }

    // MARK: History

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(image); image = last; selection = nil; floating = nil
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(image); image = next; selection = nil; floating = nil
    }

    private func push() {
        undoStack.append(image)
        if undoStack.count > 25 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Draws on top of the current bitmap (UIKit coordinates, 1 pt = 1 px) as one undo step
    private func edit(_ draw: (CGContext) -> Void) {
        push()
        let current = image
        image = render(current.size) { ctx in
            current.draw(at: .zero)
            draw(ctx)
        }
    }

    private func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { draw($0.cgContext) }
    }

    private static func blank(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    static func shapePath(_ tool: Tool, _ a: CGPoint, _ b: CGPoint) -> Path? {
        switch tool {
        case .line: var p = Path(); p.move(to: a); p.addLine(to: b); return p
        case .rectangle: return Path(rect(a, b))
        case .ellipse: return Path(ellipseIn: rect(a, b))
        default: return nil
        }
    }
}
