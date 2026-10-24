import SwiftUI

public struct KlangschriftNotePair: Shape {
    public init() {}
    public func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addEllipse(in: CGRect(x: 6, y: 64, width: 31, height: 22))
        p.addEllipse(in: CGRect(x: 61, y: 52, width: 31, height: 22))
        p.addRect(CGRect(x: 29, y: 21, width: 8, height: 55))
        p.addRect(CGRect(x: 84, y: 9, width: 8, height: 55))
        p.move(to: CGPoint(x: 29,y: 21)); p.addLine(to: CGPoint(x: 92,y: 7)); p.addLine(to: CGPoint(x: 92,y: 23)); p.addLine(to: CGPoint(x: 29,y: 37)); p.closeSubpath()
        let scale = min(rect.width/100, rect.height/100)
        return p.applying(CGAffineTransform(translationX: rect.minX+(rect.width-100*scale)/2, y: rect.minY+(rect.height-100*scale)/2).scaledBy(x: scale,y: scale))
    }
}
