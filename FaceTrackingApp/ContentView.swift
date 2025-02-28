//
//  ContentView.swift
//  FaceTrackingApp
//
//  Created by Corey Lofthus on 2/28/25.
//

import SwiftUI
import AVFoundation
import Vision

// Model to store facial landmark positions and expression metrics.
struct FaceLandmarks {
    var leftEye: CGPoint
    var rightEye: CGPoint
    var mouth: CGPoint
    var leftEyeBlink: Bool
    var rightEyeBlink: Bool
    var mouthOpen: CGFloat
    var smileFactor: CGFloat  // Positive = smile, Negative = frown.
}

// ViewModel to publish detected landmarks for SwiftUI to consume.
class FaceDetectionViewModel: ObservableObject {
    @Published var landmarks: FaceLandmarks?
}

// The main SwiftUI view.
struct ContentView: View {
    @StateObject var viewModel = FaceDetectionViewModel()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera view as background.
                CameraView(viewModel: viewModel)
                    .edgesIgnoringSafeArea(.all)
                
                // Overlay facial features: eyes and mouth.
                if let landmarks = viewModel.landmarks {
                    // Left eye: if blinking, show a horizontal line; otherwise, a circle.
                    if landmarks.leftEyeBlink {
                        Path { path in
                            path.move(to: CGPoint(x: landmarks.leftEye.x - 20, y: landmarks.leftEye.y))
                            path.addLine(to: CGPoint(x: landmarks.leftEye.x + 20, y: landmarks.leftEye.y))
                        }
                        .stroke(Color.red, lineWidth: 3)
                    } else {
                        Circle()
                            .stroke(Color.red, lineWidth: 3)
                            .frame(width: 40, height: 40)
                            .position(landmarks.leftEye)
                    }
                    
                    // Right eye.
                    if landmarks.rightEyeBlink {
                        Path { path in
                            path.move(to: CGPoint(x: landmarks.rightEye.x - 20, y: landmarks.rightEye.y))
                            path.addLine(to: CGPoint(x: landmarks.rightEye.x + 20, y: landmarks.rightEye.y))
                        }
                        .stroke(Color.red, lineWidth: 3)
                    } else {
                        Circle()
                            .stroke(Color.red, lineWidth: 3)
                            .frame(width: 40, height: 40)
                            .position(landmarks.rightEye)
                    }
                    
                    // Mouth: shape changes based on mouth openness and smile/frown.
                    MouthShape(mouthOpen: landmarks.mouthOpen, smileFactor: landmarks.smileFactor)
                        .stroke(Color.blue, lineWidth: 3)
                        .frame(width: 80, height: 40)
                        .position(landmarks.mouth)
                }
            }
        }
    }
}

// A custom shape to represent the mouth as a quadratic curve.
// The control point's vertical offset is influenced by both the mouthOpen value and smileFactor.
struct MouthShape: Shape {
    var mouthOpen: CGFloat
    var smileFactor: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.midY)
        let end = CGPoint(x: rect.maxX, y: rect.midY)
        // The basic offset for mouth openness.
        let openOffset = 40 * mouthOpen
        // The smileFactor adjusts the curve: positive for smile (raising the curve), negative for frown.
        let expressionOffset = -20 * smileFactor
        let control = CGPoint(x: rect.midX, y: rect.midY + openOffset + expressionOffset)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

// A UIViewRepresentable that wraps the camera preview and handles video capture.
struct CameraView: UIViewRepresentable {
    @ObservedObject var viewModel: FaceDetectionViewModel
    
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.setupSession(viewModel: viewModel)
        return view
    }
    
    func updateUIView(_ uiView: PreviewView, context: Context) {
        // No dynamic update needed.
    }
}

// UIView subclass that configures the AVCaptureSession and handles video processing.
class PreviewView: UIView {
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "sessionQueue")
    
    private var viewModel: FaceDetectionViewModel?
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        session.sessionPreset = .high
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setupSession(viewModel: FaceDetectionViewModel) {
        self.viewModel = viewModel
        sessionQueue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
    }
    
    /// Helper function that converts an array of normalized Vision points into converted points,
    /// then returns both the average position and the aspect ratio (height/width) of the points.
    private func computeCenterAndAspect(for points: [CGPoint]?) -> (center: CGPoint, aspect: CGFloat)? {
        guard let points = points, !points.isEmpty else { return nil }
        let converted = points.map {
            previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x, y: 1 - $0.y))
        }
        let sum = converted.reduce(CGPoint.zero) { (result, point) -> CGPoint in
            CGPoint(x: result.x + point.x, y: result.y + point.y)
        }
        let avg = CGPoint(x: sum.x / CGFloat(converted.count), y: sum.y / CGFloat(converted.count))
        let minX = converted.map { $0.x }.min() ?? 0
        let maxX = converted.map { $0.x }.max() ?? 0
        let minY = converted.map { $0.y }.min() ?? 0
        let maxY = converted.map { $0.y }.max() ?? 0
        let width = maxX - minX
        let height = maxY - minY
        let aspect = (width > 0) ? (height / width) : 0
        return (center: avg, aspect: aspect)
    }
    
    private func configureSession() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
            
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
            if session.canAddOutput(videoDataOutput) {
                session.addOutput(videoDataOutput)
            }
            
            // Set video orientation to portrait and mirror the front camera.
            if let connection = videoDataOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
                connection.isVideoMirrored = true
            }
        } catch {
            print("Error configuring session: \(error)")
        }
    }
}

extension PreviewView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let viewModel = viewModel else { return }
        
        // Use VNImageRequestHandler with proper orientation.
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self = self else { return }
            if let results = request.results as? [VNFaceObservation],
               let observation = results.first,
               let landmarks = observation.landmarks {
                
                // Set a slightly more sensitive blink threshold.
                let blinkThreshold: CGFloat = 0.3
                
                // Process left eye.
                var leftEyeCenter = CGPoint.zero
                var leftEyeBlink = false
                if let leftEyeData = self.computeCenterAndAspect(for: landmarks.leftEye?.normalizedPoints) {
                    leftEyeCenter = leftEyeData.center
                    let aspectRatio = leftEyeData.aspect
                    leftEyeBlink = aspectRatio < blinkThreshold
                }
                
                // Process right eye.
                var rightEyeCenter = CGPoint.zero
                var rightEyeBlink = false
                if let rightEyeData = self.computeCenterAndAspect(for: landmarks.rightEye?.normalizedPoints) {
                    rightEyeCenter = rightEyeData.center
                    let aspectRatio = rightEyeData.aspect
                    rightEyeBlink = aspectRatio < blinkThreshold
                }
                
                // Adjust eye positions: move left eye slightly right & down, right eye slightly left & down.
                leftEyeCenter.x += 5
                leftEyeCenter.y += 10
                rightEyeCenter.x -= 5
                rightEyeCenter.y += 10
                
                // Process mouth.
                var mouthCenter = CGPoint.zero
                var mouthOpen: CGFloat = 0.0
                var smileFactor: CGFloat = 0.0
                if let mouthPoints = landmarks.outerLips?.normalizedPoints, !mouthPoints.isEmpty {
                    let convertedLips = mouthPoints.map {
                        self.previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x, y: 1 - $0.y))
                    }
                    // Compute mouth center.
                    let sum = convertedLips.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
                    mouthCenter = CGPoint(x: sum.x / CGFloat(convertedLips.count), y: sum.y / CGFloat(convertedLips.count))
                    
                    // Compute mouth openness based on bounding box aspect ratio.
                    let minX = convertedLips.map { $0.x }.min() ?? 0
                    let maxX = convertedLips.map { $0.x }.max() ?? 0
                    let minY = convertedLips.map { $0.y }.min() ?? 0
                    let maxY = convertedLips.map { $0.y }.max() ?? 0
                    let width = maxX - minX
                    let height = maxY - minY
                    let aspect = (width > 0) ? (height / width) : 0
                    let rawMouthRatio = aspect
                    let baseline: CGFloat = 0.15
                    let adjusted = max(rawMouthRatio - baseline, 0)
                    mouthOpen = min(adjusted * 5.0, 1.0)
                    
                    // Compute smile/frown factor.
                    // Identify mouth corners.
                    let leftCorner = convertedLips.min(by: { $0.x < $1.x })!
                    let rightCorner = convertedLips.max(by: { $0.x < $1.x })!
                    let midX = (leftCorner.x + rightCorner.x) / 2
                    // Line connecting the corners.
                    let slope = (rightCorner.y - leftCorner.y) / (rightCorner.x - leftCorner.x)
                    let b = leftCorner.y - slope * leftCorner.x
                    let expectedY = slope * midX + b
                    // Delta: if mouth center is above the line, delta is positive (smile); if below, negative (frown).
                    let delta = expectedY - mouthCenter.y
                    // Normalize delta (adjust divisor as needed for sensitivity).
                    smileFactor = max(min(delta / 20.0, 1), -1)
                }
                
                // Adjust mouth position: raise it slightly.
                mouthCenter.y -= 10
                
                DispatchQueue.main.async {
                    viewModel.landmarks = FaceLandmarks(
                        leftEye: leftEyeCenter,
                        rightEye: rightEyeCenter,
                        mouth: mouthCenter,
                        leftEyeBlink: leftEyeBlink,
                        rightEyeBlink: rightEyeBlink,
                        mouthOpen: mouthOpen,
                        smileFactor: smileFactor
                    )
                }
            } else {
                DispatchQueue.main.async {
                    viewModel.landmarks = nil
                }
            }
        }
        
        do {
            try requestHandler.perform([faceLandmarksRequest])
        } catch {
            print("Failed to perform face landmarks request: \(error)")
        }
    }
}

#Preview {
    ContentView()
}
