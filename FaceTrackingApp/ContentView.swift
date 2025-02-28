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
                    // Left eye: if blinking, show a line; otherwise, a circle.
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
                    
                    // Mouth: shape changes based on how open the mouth is.
                    MouthShape(mouthOpen: landmarks.mouthOpen)
                        .stroke(Color.blue, lineWidth: 3)
                        .frame(width: 80, height: 40)
                        .position(landmarks.mouth)
                }
            }
        }
    }
}

// A custom shape to represent the mouth as a quadratic curve.
// The control point is adjusted based on the 'mouthOpen' parameter.
struct MouthShape: Shape {
    var mouthOpen: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: rect.minX, y: rect.midY)
        let end = CGPoint(x: rect.maxX, y: rect.midY)
        // Adjust the control point's vertical offset based on mouthOpen.
        let control = CGPoint(x: rect.midX, y: rect.midY + 10 * mouthOpen)
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
    
    // Converts an array of normalized Vision points into a bounding CGRect in the preview layer's coordinate system.
    private func boundingRectConverted(_ points: [CGPoint]?) -> CGRect? {
        guard let points = points, !points.isEmpty else { return nil }
        let convertedPoints = points.map {
            previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: $0.x, y: 1 - $0.y))
        }
        guard let first = convertedPoints.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for pt in convertedPoints {
            minX = min(minX, pt.x)
            maxX = max(maxX, pt.x)
            minY = min(minY, pt.y)
            maxY = max(maxY, pt.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
                
                // Define a blink threshold: if the eye aspect ratio is below this, consider it a blink.
                let blinkThreshold: CGFloat = 0.2
                
                // Process left eye.
                var leftEyeCenter = CGPoint.zero
                var leftEyeBlink = false
                if let leftEyeRect = self.boundingRectConverted(landmarks.leftEye?.normalizedPoints) {
                    leftEyeCenter = CGPoint(x: leftEyeRect.midX, y: leftEyeRect.midY)
                    let aspectRatio = leftEyeRect.height / leftEyeRect.width
                    leftEyeBlink = aspectRatio < blinkThreshold
                }
                
                // Process right eye.
                var rightEyeCenter = CGPoint.zero
                var rightEyeBlink = false
                if let rightEyeRect = self.boundingRectConverted(landmarks.rightEye?.normalizedPoints) {
                    rightEyeCenter = CGPoint(x: rightEyeRect.midX, y: rightEyeRect.midY)
                    let aspectRatio = rightEyeRect.height / rightEyeRect.width
                    rightEyeBlink = aspectRatio < blinkThreshold
                }
                
                // Process mouth.
                var mouthCenter = CGPoint.zero
                var mouthOpen: CGFloat = 0.0
                if let mouthRect = self.boundingRectConverted(landmarks.outerLips?.normalizedPoints) {
                    mouthCenter = CGPoint(x: mouthRect.midX, y: mouthRect.midY)
                    // Calculate mouth open ratio based on the height-to-width ratio.
                    mouthOpen = mouthRect.height / mouthRect.width
                    // Clamp the value between 0 and 1 for our UI.
                    mouthOpen = min(max(mouthOpen, 0), 1)
                }
                
                DispatchQueue.main.async {
                    // Only update if we have valid positions.
                    viewModel.landmarks = FaceLandmarks(
                        leftEye: leftEyeCenter,
                        rightEye: rightEyeCenter,
                        mouth: mouthCenter,
                        leftEyeBlink: leftEyeBlink,
                        rightEyeBlink: rightEyeBlink,
                        mouthOpen: mouthOpen
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
