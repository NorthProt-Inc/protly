public enum Privacy { case `public`, `private` }
public struct LogMsg: ExpressibleByStringInterpolation {
  public struct StringInterpolation: StringInterpolationProtocol {
    var s = ""
    public init(literalCapacity: Int, interpolationCount: Int) {}
    public mutating func appendLiteral(_ l: String) { s += l }
    public mutating func appendInterpolation<T>(_ v: T, privacy: Privacy) { s += "\(v)" }
  }
  let s: String
  public init(stringLiteral: String) { s = stringLiteral }
  public init(stringInterpolation: StringInterpolation) { s = stringInterpolation.s }
}
public struct Logger: Sendable {
  public init(subsystem: String, category: String) {}
  public func debug(_ m: LogMsg) { print("LOG", m.s) }
}
