import Foundation

/// 画布视口的唯一数据事实源，供画布、缩略图和恢复层共享。
public struct CanvasViewportState: Codable, Equatable, Sendable, Hashable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public var center: Point
    public var zoom: Double
    public var canvasSize: Size

    public init(
        center: Point = Point(x: 0, y: 0),
        zoom: Double = 1,
        canvasSize: Size = Size(width: 0, height: 0),
        schemaVersion: Int = CanvasViewportState.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.center = center
        self.zoom = zoom.clamped(to: 0.1...8)
        self.canvasSize = canvasSize
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, center, zoom, canvasSize }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.center = try c.decode(Point.self, forKey: .center)
        self.zoom = try c.decode(Double.self, forKey: .zoom)
        self.canvasSize = try c.decode(Size.self, forKey: .canvasSize)
        guard zoom.isFinite, zoom >= 0.1, zoom <= 8 else {
            throw CanvasSchemaError.invalidField("viewport.zoom")
        }
        try validate()
    }

    public func validate() throws {
        try center.validate()
        guard zoom.isFinite, zoom >= 0.1, zoom <= 8 else {
            throw CanvasSchemaError.invalidField("viewport.zoom")
        }
        try canvasSize.validate()
    }

    public var isValid: Bool { (try? validate()) != nil }

    public mutating func setZoom(_ value: Double) {
        zoom = value.clamped(to: 0.1...8)
    }

    public mutating func pan(by delta: Point) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        center = Point(x: center.x + delta.x, y: center.y + delta.y)
    }

    public func minimapPoint(for canvasPoint: Point, in minimapSize: Size) -> Point {
        guard canvasSize.width > 0, canvasSize.height > 0,
              minimapSize.width > 0, minimapSize.height > 0 else {
            return Point(x: minimapSize.width / 2, y: minimapSize.height / 2)
        }
        return Point(
            x: (canvasPoint.x / canvasSize.width * minimapSize.width).clamped(to: 0...minimapSize.width),
            y: (canvasPoint.y / canvasSize.height * minimapSize.height).clamped(to: 0...minimapSize.height)
        )
    }
}

public struct Size: Codable, Equatable, Sendable, Hashable {
    public static let currentSchemaVersion = CanvasSchema.currentVersion
    public let schemaVersion: Int
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double, schemaVersion: Int = Size.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, width, height }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try CanvasSchema.decodeVersion(from: c, key: .schemaVersion)
        self.width = try c.decode(Double.self, forKey: .width)
        self.height = try c.decode(Double.self, forKey: .height)
        try validate()
    }

    public func validate() throws {
        guard width.isFinite, height.isFinite, width >= 0, height >= 0 else {
            throw CanvasSchemaError.invalidField("size")
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
