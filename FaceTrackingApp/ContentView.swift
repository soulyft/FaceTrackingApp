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
                
                // Overlay basic facial features: eyes and mouth.
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
        // Draw a simple arc-like curve for the mouth.
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
    
    // Helper function: averages an array of points and converts from Vision’s normalized coordinates
    // into the previewLayer’s coordinate system.
    private func averageAndConvert(_ points: [CGPoint]?) -> CGPoint? {
        guard let points = points, !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { (result, point) -> CGPoint in
            CGPoint(x: result.x + point.x, y: result.y + point.y)
        }
        let count = CGFloat(points.count)
        let avg = CGPoint(x: sum.x / count, y: sum.y / count)
        // Vision’s normalized coordinates have the origin at the bottom-left.
        // Adjust by flipping the y coordinate before converting.
        let adjusted = CGPoint(x: avg.x, y: 1 - avg.y)
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: adjusted)
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
            
            // Set the video orientation to portrait and mirror the front camera.
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
        
        // Use VNImageRequestHandler with the appropriate orientation.
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let self = self else { return }
            if let results = request.results as? [VNFaceObservation],
               let observation = results.first,
               let landmarks = observation.landmarks {
                // Convert landmark points for eyes and mouth using our helper.
                let leftEyePoint = self.averageAndConvert(landmarks.leftEye?.normalizedPoints)
                let rightEyePoint = self.averageAndConvert(landmarks.rightEye?.normalizedPoints)
                let mouthPoint = self.averageAndConvert(landmarks.outerLips?.normalizedPoints)
                
                DispatchQueue.main.async {
                    if let left = leftEyePoint, let right = rightEyePoint, let mouth = mouthPoint {
                        viewModel.landmarks = FaceLandmarks(leftEye: left, rightEye: right, mouth: mouth)
                    } else {
                        viewModel.landmarks = nil
                    }
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
