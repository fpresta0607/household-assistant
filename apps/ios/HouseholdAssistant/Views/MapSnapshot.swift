// A picture of the map round a place, drawn by MapKit on the phone, with whatever a card
// puts on it placed by the picture's own projection: a face, a pin, the way there, the
// circle round a place. Apple draws the tiles, which is all it hears of the place.
//
// Each picture is made once for its region, size and look and kept while the app runs,
// so scrolling back past a map does not draw it again. Until it arrives, a quiet panel
// with the map symbol, and then the map comes into focus from a blur.

import MapKit
import SwiftUI

struct MapSnapshot<Marks: View>: View {
    let region: MKCoordinateRegion
    var height: CGFloat = 140
    @ViewBuilder let marks: (MapProjection) -> Marks

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.reducesMotion) private var reduceMotion
    @State private var picture: MapPicture?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                if let picture, picture.size == size {
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: picture.image)
                            .resizable()
                            .frame(width: size.width, height: size.height)
                        marks(picture.projection)
                    }
                    .transition(Motion.blurUpTransition(reduced: reduceMotion))
                } else {
                    Rectangle()
                        .fill(Palette.surface)
                        .overlay {
                            Image(systemName: "map")
                                .font(.title3)
                                .foregroundStyle(Palette.secondaryText)
                        }
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(Motion.reveal(reduced: reduceMotion), value: picture?.size == size)
            .task(id: MapPicture.key(region: region, size: size, isDark: colorScheme == .dark)) {
                picture = await MapPicture.make(region: region, size: size, isDark: colorScheme == .dark)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// One map picture, made by MapKit and kept for its region, size and look.
@MainActor
private struct MapPicture {
    let image: UIImage
    let size: CGSize
    let projection: MapProjection

    private static var made: [String: MapPicture] = [:]

    static func key(region: MKCoordinateRegion, size: CGSize, isDark: Bool) -> String {
        [region.center.latitude, region.center.longitude, region.span.latitudeDelta, region.span.longitudeDelta, Double(size.width), Double(size.height)]
            .map { String(format: "%.5f", $0) }
            .joined(separator: ",") + (isDark ? ",dark" : ",light")
    }

    static func make(region: MKCoordinateRegion, size: CGSize, isDark: Bool) async -> MapPicture? {
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let key = key(region: region, size: size, isDark: isDark)
        if let kept = made[key] {
            return kept
        }
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.traitCollection = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        options.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else {
            return nil
        }
        let picture = MapPicture(image: snapshot.image, size: size, projection: MapProjection { snapshot.point(for: $0) })
        made[key] = picture
        return picture
    }
}
