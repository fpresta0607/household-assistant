// A message bubble: rounded, with a tail at the bottom on the speaker's side
// when it is the last bubble of its run.
//
// The bubble is one outline. The rectangle's corner on the tail's side is squared off,
// and the tail is joined to it, so a stroke round an assistant's bubble (AssistantRim)
// follows the bubble's own edge only. Two separate outlines filled the same but stroked
// as a rectangle with a square corner and a seam where the tail met it.

import SwiftUI

// File-scope, not static members: `path(in:)` is nonisolated, and a static on
// a Shape is main-actor through View, which Swift 6 would refuse to read here.
private let bubbleCornerRadius: CGFloat = 18
private let bubbleTailWidth: CGFloat = 6
private let bubbleTailHeight: CGFloat = 14

struct BubbleShape: Shape {
    /// The tail sits on the trailing side: this phone's owner speaking.
    let isTrailing: Bool
    let hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius = bubbleCornerRadius
        let tailCorner: CGFloat = hasTail ? 0 : radius
        let body = UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: isTrailing ? radius : tailCorner,
            bottomTrailingRadius: isTrailing ? tailCorner : radius,
            topTrailingRadius: radius,
            style: .continuous
        )
        .path(in: rect)
        guard hasTail else {
            return body
        }
        let edge = isTrailing ? rect.maxX : rect.minX
        let outward: CGFloat = isTrailing ? 1 : -1
        // The tail reaches a point inside the square corner, so the two overlap and the
        // union leaves no sliver along the edge they share.
        let inside = edge - outward * 2
        var tail = Path()
        tail.move(to: CGPoint(x: edge, y: rect.maxY - bubbleTailHeight))
        tail.addQuadCurve(
            to: CGPoint(x: edge + outward * bubbleTailWidth, y: rect.maxY),
            control: CGPoint(x: edge, y: rect.maxY - 2)
        )
        tail.addLine(to: CGPoint(x: inside, y: rect.maxY))
        tail.addLine(to: CGPoint(x: inside, y: rect.maxY - bubbleTailHeight))
        tail.closeSubpath()
        return body.union(tail)
    }
}
