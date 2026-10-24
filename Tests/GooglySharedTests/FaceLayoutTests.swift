import XCTest
@testable import GooglyShared

final class FaceLayoutTests: XCTestCase {
    private let phones: [(String, CGSize, CGFloat)] = [
        ("SE", CGSize(width: 375, height: 667), 20),
        ("15", CGSize(width: 393, height: 852), 59),
        ("16 Pro", CGSize(width: 402, height: 874), 62),
        ("16 Pro Max", CGSize(width: 430, height: 932), 62),
    ]

    func testScaleFollowsWidthAndAnchorsToTheBottom() {
        for (name, size, _) in phones {
            let s = FaceLayout.scale(for: size)
            XCTAssertEqual(s, size.width / 390, accuracy: 0.0001, name)
            XCTAssertEqual(FaceLayout.originY(for: size) + FaceLayout.design.height * s, size.height, accuracy: 0.001, name)
            XCTAssertGreaterThan(s, 0, name)
        }
        XCTAssertEqual(FaceLayout.scale(for: .zero), 1)
    }

    func testFaceFitsInsideEveryPhone() {
        for (name, size, inset) in phones {
            let s = FaceLayout.scale(for: size)
            let top = FaceLayout.originY(for: size)
            // Chrome (chip and buttons) ends about 40 pt below the safe area.
            let chromeBottom = max(inset, 20) + 44
            XCTAssertGreaterThan(top + FaceLayout.topmostFeatureY * s, chromeBottom + 40, "\(name): face collides with the top chrome")
            XCTAssertLessThanOrEqual(top + FaceLayout.lowestFeatureY * s, size.height, "\(name): mouth below the screen")
            for cx in FaceLayout.eyeCenters {
                let half = FaceLayout.eyeSize.width / 2
                XCTAssertGreaterThanOrEqual((cx - half) * s, 0, "\(name): eye off the left edge")
                XCTAssertLessThanOrEqual((cx + half) * s, size.width, "\(name): eye off the right edge")
            }
        }
    }

    func testEyesSitInsideTheBodyDome() {
        // Half-width of the dome (top corners are ~250 pt circles) at a given design y.
        func halfWidth(at y: CGFloat) -> CGFloat {
            let r: CGFloat = 250
            let centerY = FaceLayout.body.minY + r
            guard y < centerY else { return FaceLayout.body.width / 2 }
            let dy = centerY - y
            return dy >= r ? 0 : sqrt(r * r - dy * dy) + (FaceLayout.body.width / 2 - r)
        }
        let center = FaceLayout.body.midX
        for cx in FaceLayout.eyeCenters {
            XCTAssertLessThan(abs(cx - center) + FaceLayout.eyeSize.width / 2, halfWidth(at: FaceLayout.eyeY - FaceLayout.eyeSize.height / 2))
        }
    }

    func testPupilNeverLeavesTheEye() {
        let rx = FaceLayout.eyeSize.width / 2, ry = FaceLayout.eyeSize.height / 2
        for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 18) {
            // Gaze is normalised to the unit circle before it is scaled by the reach.
            let px = cos(angle) * FaceLayout.gazeReach.width
            let py = sin(angle) * FaceLayout.gazeReach.height
            // The pupil's center stays well inside the white; the white is clipped around larger (happy) pupils.
            XCTAssertLessThan((px / rx) * (px / rx) + (py / ry) * (py / ry), 0.35)
            XCTAssertLessThan(FaceLayout.gazeReach.width, rx - FaceLayout.pupilRadius + 1)
            XCTAssertLessThan(FaceLayout.gazeReach.height, ry - FaceLayout.pupilRadius + 1)
        }
    }

    func testCornerRadiusTable() {
        XCTAssertEqual(FaceLayout.screenCornerRadius(nativeHeight: 2556), 55)
        XCTAssertEqual(FaceLayout.screenCornerRadius(nativeHeight: 2622), 62)
        XCTAssertEqual(FaceLayout.screenCornerRadius(nativeHeight: 1334), 0)
        XCTAssertEqual(FaceLayout.screenCornerRadius(nativeHeight: 99999), 55)
    }
}
