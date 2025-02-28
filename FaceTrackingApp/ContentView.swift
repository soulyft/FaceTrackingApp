//
//  ContentView.swift
//  FaceTrackingApp
//
//  Created by Corey Lofthus on 2/28/25.
//

import SwiftUI
import AVFoundation
import Vision

// Model to store facial landmark positions
struct FaceLandmarks {
    var leftEye: CGPoint
    var rightEye: CGPoint
    var mouth: CGPoint
}

// ViewModel to publish detected landmarks for SwiftUI to consume
class FaceDetectionViewModel: ObservableObject {
    @Published var landmarks: FaceLandmarks?
    
    func updateLandmarks(from observation: VNFaceObservation, in frameSize: CGSize) {
        guard let landmarks2D = observation.landmarks else { return }
        
        // Average normalized points to compute positions in the frame
        let leftEyePosition = averagePoint(from: landmarks2D.leftEye?.normalizedPoints, frameSize: frameSize)
        let rightEyePosition = averagePoint(from: landmarks2D.rightEye?.normalizedPoints, frameSize: frameSize)
        let mouthPosition = averagePoint(from: landmarks2D.outerLips?.normalizedPoints, frameSize: frameSize)
        
        if let left = leftEyePosition, let right = rightEyePosition, let mouth = mouthPosition {
            DispatchQueue.main.async {
                self.landmarks = FaceLandmarks(leftEye: left, rightEye: right, mouth: mouth)
            }
        }
    }
    
    private func averagePoint(from points: [CGPoint]?, frameSize: CGSize) -> CGPoint? {
        guard let points = points, !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { (result, point) -> CGPoint in
            CGPoint(x: result.x + point.x, y: result.y + point.y)
        }
        let count = CGFloat(points.count)
        // Convert from normalized (0-1) coordinates to actual frame coordinates
        return CGPoint(x: (sum.x / count) * frameSize.width,
                       y: (1 - sum.y / count) * frameSize.height)
    }
}

// The main SwiftUI view
struct ContentView: View {
    @StateObject var viewModel = FaceDetectionViewModel()
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera view as background
                CameraView(viewModel: viewModel)
                    .edgesIgnoringSafeArea(.all)
                
                // Overlay geometric shapes for detected landmarks
                if let landmarks = viewModel.landmarks {
                    // Left eye
                    Circle()
                        .stroke(Color.red, lineWidth: 3)
                        .frame(width: 40, height: 40)
                        .position(landmarks.leftEye)
                    
                    // Right eye
                    Circle()
                        .stroke(Color.red, lineWidth: 3)
                        .frame(width: 40, height: 40)
                        .position(landmarks.rightEye)
                    
                    // Mouth (using a custom shape)
                    MouthShape()
                        .stroke(Color.blue, lineWidth: 3)
                        .frame(width: 80, height: 40)
                        .position(landmarks.mouth)
                }
            }
        }
    }
}

// A simple custom shape to represent the mouth as a quadratic curve.
struct MouthShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Draw an arc-like curve; adjust the control point for a smile or frown.
        let start = CGPoint(x: rect.minX, y: rect.midY)
        let end = CGPoint(x: rect.maxX, y: rect.midY)
        let control = CGPoint(x: rect.midX, y: rect.midY + 10)
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
        // No dynamic update needed
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
            
            // Ensure the video is in portrait mode
            if let connection = videoDataOutput.connection(with: .video) {
                connection.videoOrientation = .portrait
                // For the front camera, mirror the image
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
        
        // Get the dimensions of the frame
        let frameWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let frameHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let frameSize = CGSize(width: frameWidth, height: frameHeight)
        
        // Create a Vision request handler
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest { request, error in
            if let results = request.results as? [VNFaceObservation],
               let observation = results.first {
                viewModel.updateLandmarks(from: observation, in: frameSize)
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
