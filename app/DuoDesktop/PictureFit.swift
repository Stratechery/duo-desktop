import CoreGraphics

/// Where the Mac's picture sits inside the 16:9 frame (reviewer plan review, finding 1). The frame stays 16:9; the
/// picture the Host actually sends keeps its own shape. In Scale mode the Host fits the display's shape into the
/// 1920 x 1080 request and never enlarges past native pixels, so a 1600 x 1000 display arrives as 1600 x 1000
/// and a large 16:10 one as 1728 x 1080. The picture is aspect-fitted (never stretched) and centred, on whole
/// device pixels. The pointer's bounds come from the same negotiated canvas (`TrackpadEngine.setCanvas`).
enum PictureFit {
    /// The picture's rectangle in the frame, in points. `.zero` if either size is empty.
    static func frame(canvasWidth: Int, canvasHeight: Int, in bounds: CGSize, screenScale: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, canvasWidth > 0, canvasHeight > 0 else { return .zero }
        let fit = min(bounds.width / CGFloat(canvasWidth), bounds.height / CGFloat(canvasHeight))
        let w = CGFloat(canvasWidth) * fit, h = CGFloat(canvasHeight) * fit
        let s = max(1, screenScale)
        let x = ((bounds.width - w) / 2 * s).rounded() / s
        let y = ((bounds.height - h) / 2 * s).rounded() / s
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// The fitted picture zoomed (1 = fit) about the view's centre and moved by `pan` points (the horizontal
    /// layout's pinch). `pan` is first limited so the picture can't be dragged off the view; the limited pan is
    /// returned with the frame.
    static func zoomed(canvasWidth: Int, canvasHeight: Int, in bounds: CGSize, screenScale: CGFloat,
                       zoom: CGFloat, pan: CGPoint) -> (frame: CGRect, pan: CGPoint) {
        let fit = frame(canvasWidth: canvasWidth, canvasHeight: canvasHeight, in: bounds, screenScale: screenScale)
        guard fit.width > 0, zoom > 1 else { return (fit, .zero) }
        let w = fit.width * zoom, h = fit.height * zoom
        let maxX = max(0, (w - bounds.width) / 2), maxY = max(0, (h - bounds.height) / 2)
        let p = CGPoint(x: min(maxX, max(-maxX, pan.x)), y: min(maxY, max(-maxY, pan.y)))
        let s = max(1, screenScale)
        var x = (((bounds.width - w) / 2 + p.x) * s).rounded() / s
        var y = (((bounds.height - h) / 2 + p.y) * s).rounded() / s
        // A picture bigger than the view always covers it: rounding to device pixels never opens a sliver of black
        // at an edge (the centred view at the screen's right or bottom edge).
        if w >= bounds.width { x = min(0, max(x, ((bounds.width - w) * s).rounded(.up) / s)) }
        if h >= bounds.height { y = min(0, max(y, ((bounds.height - h) * s).rounded(.up) / s)) }
        return (CGRect(x: x, y: y, width: w, height: h), p)
    }

    /// The centred view's zoom: half the Mac screen's width and height in the same frame.
    static let centredZoom: CGFloat = 2

    /// The pan that puts canvas point (x, y) at the view's centre at `zoom`. Pass it to `zoomed`, which stops it at
    /// the screen's edges, so near an edge or corner the pointer leaves the centre and no empty area is shown.
    static func pan(centring x: CGFloat, _ y: CGFloat, canvasWidth: Int, canvasHeight: Int, in bounds: CGSize,
                    screenScale: CGFloat, zoom: CGFloat) -> CGPoint {
        let fit = frame(canvasWidth: canvasWidth, canvasHeight: canvasHeight, in: bounds, screenScale: screenScale)
        guard fit.width > 0 else { return .zero }
        let w = fit.width * zoom, h = fit.height * zoom
        return CGPoint(x: w * (0.5 - x / CGFloat(canvasWidth)), y: h * (0.5 - y / CGFloat(canvasHeight)))
    }

    /// The part of the canvas a zoomed `picture` frame shows in `bounds`, in canvas pixels.
    static func viewport(picture: CGRect, canvasWidth: Int, in bounds: CGSize) -> CGRect {
        guard picture.width > 0, canvasWidth > 0 else { return .zero }
        let k = picture.width / CGFloat(canvasWidth)
        return CGRect(x: -picture.minX / k, y: -picture.minY / k, width: bounds.width / k, height: bounds.height / k)
    }

    /// A canvas pixel's position in the frame, in points (where the pointer is drawn).
    static func point(canvasX: Int, canvasY: Int, canvasWidth: Int, canvasHeight: Int, in bounds: CGSize,
                      screenScale: CGFloat) -> CGPoint {
        let f = frame(canvasWidth: canvasWidth, canvasHeight: canvasHeight, in: bounds, screenScale: screenScale)
        guard canvasWidth > 0 else { return .zero }
        let k = f.width / CGFloat(canvasWidth)
        return CGPoint(x: f.minX + CGFloat(canvasX) * k, y: f.minY + CGFloat(canvasY) * k)
    }
}
