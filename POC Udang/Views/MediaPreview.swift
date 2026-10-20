import SwiftUI
import UIKit

struct MediaPreview: View {
    let image: UIImage?
    let objects: [TrackedObject]
    var showIDs = true
    var showBoxes = true
    var showConfidence = true
    var cornerRadius: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.94)
                if let image {
                    let scale = min(geometry.size.width / image.size.width, geometry.size.height / image.size.height)
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                    Canvas { context, _ in
                        for object in objects where object.hasValidBox {
                            let color = object.ambiguous ? .orange : object.trackID.map { Color(hue: Double(($0 * 137) % 360) / 360, saturation: 0.8, brightness: 1) } ?? .cyan
                            let b = object.bbox
                            let rect = CGRect(x: b[0] * size.width, y: b[1] * size.height,
                                              width: (b[2] - b[0]) * size.width, height: (b[3] - b[1]) * size.height)
                            if let label = label(for: object) {
                                // Attach the label to the box corner; confidence uses smaller text.
                                let text = context.resolve(label.foregroundColor(.white))
                                let textSize = text.measure(in: size)
                                let labelSize = CGSize(width: textSize.width + 2, height: textSize.height + 1)
                                let rightAligned = rect.minX + labelSize.width > size.width
                                let bottomAligned = rect.minY + labelSize.height > size.height
                                let origin = CGPoint(x: rightAligned ? rect.maxX - labelSize.width : rect.minX,
                                                     y: bottomAligned ? rect.maxY - labelSize.height : rect.minY)
                                let badge = Path(CGRect(origin: origin, size: labelSize))
                                context.fill(badge, with: .color(.black.opacity(0.45)))
                                context.stroke(badge, with: .color(color.opacity(0.8)), lineWidth: 0.5)
                                context.draw(text, at: CGPoint(x: origin.x + 1, y: origin.y + 0.5), anchor: .topLeading)
                            }
                            if showBoxes {
                                // Outline last so the ID badge cannot hide a small bounding box.
                                context.stroke(Path(rect), with: .color(.black.opacity(0.35)), lineWidth: 1.5)
                                context.stroke(Path(rect), with: .color(color), lineWidth: 1)
                            }
                        }
                    }.frame(width: size.width, height: size.height).clipped()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 38))
                        Text("Media dan hasil akan tampil di sini").font(.subheadline)
                    }.foregroundStyle(.white.opacity(0.6))
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private func label(for object: TrackedObject) -> Text? {
        let score = Text("\(Int(object.confidence * 100))%")
            .font(.system(size: 8, weight: .regular))
        if showIDs, let id = object.trackID {
            let idText = Text("ID \(id)\(object.ambiguous ? " ?" : "")").font(.system(size: 10, weight: .medium))
            return showConfidence ? Text("\(idText) \(score)") : idText
        }
        return showConfidence ? score : nil
    }

}
