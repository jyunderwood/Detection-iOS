import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController {
    @IBOutlet var previewView: UIImageView!
    @IBOutlet weak var stableLabel: UILabel!

    var captureSession = AVCaptureSession()
    var previewLayer = AVCaptureVideoPreviewLayer()

    // Vision parts
    private var analysisRequests = [VNRequest]()
    private let sequenceRequestHandler = VNSequenceRequestHandler()

    // Registration History
    private let maximumHistoryLength = 15
    private var transpositionHistoryPoints: [CGPoint] = []
    private var previousPixelBuffer: CVPixelBuffer?

    //The pixel buffer being held for analysis; used to serialize Vision requests
    private var currentlyAnalyzedPixelBuffer: CVPixelBuffer?

    // Queue for dispatching Vision classification and barcode requests
    private let visionQueue = DispatchQueue(label: "com.jyunderwood.Detection.serialVisionQueue")

    var barcodeDetected = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startLivePreview()
        setupVision()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stopRunning()
    }

    override func viewDidLayoutSubviews() {
        configurePreviewLayer()
    }

    fileprivate func startLivePreview() {
        captureSession.sessionPreset = AVCaptureSession.Preset.photo

        let captureDevice = AVCaptureDevice.default(for: AVMediaType.video)
        let deviceInput = try! AVCaptureDeviceInput(device: captureDevice!)
        let deviceOutput = AVCaptureVideoDataOutput()

        deviceOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
        deviceOutput.setSampleBufferDelegate(self, queue: DispatchQueue.global(qos: DispatchQoS.QoSClass.default))

        captureSession.addInput(deviceInput)
        captureSession.addOutput(deviceOutput)

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        configurePreviewLayer()

        previewView.layer.addSublayer(previewLayer)

        captureSession.startRunning()
    }

    fileprivate func showBarcode(_ identifier: String) {
        DispatchQueue.main.async {
            if self.barcodeDetected {
                // bail out early if another observation already opened the product display
                return
            }

            self.barcodeDetected = true
            self.captureSession.stopRunning()

            let alert = UIAlertController(title: "Barcode Detected", message: identifier, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { alert in
                self.barcodeDetected = false
                self.captureSession.startRunning()
            })

            self.present(alert, animated: true)
        }
    }

    @discardableResult
    fileprivate func setupVision() -> NSError? {
        // Setup Vision parts
        let error: NSError! = nil

        // setup barcode detection
        let barcodeDetection = VNDetectBarcodesRequest { (request, error) in
            if let results = request.results as? [VNBarcodeObservation] {
                if let mainBarcode = results.first {
                    if let payloadString = mainBarcode.payloadStringValue {
                        self.showBarcode(payloadString)
                    }
                }
            }
        }

        self.analysisRequests = ([barcodeDetection])

        // setup other requests

        return error
    }

    fileprivate func analyzeCurrentImage() {
        // Most Vision tasks are not rotation agnostic so it is important to pass in the orientation of the image with request to the device
        let orientation: CGImagePropertyOrientation = .up

        var requestOptions: [VNImageOption: Any] = [:]

        let requestHandler = VNImageRequestHandler(cvPixelBuffer: currentlyAnalyzedPixelBuffer!, orientation: orientation, options: requestOptions)

        visionQueue.async {
            do {
                // Release the pixel buffer when done, allowing the next buffer to be processed
                defer { self.currentlyAnalyzedPixelBuffer = nil }
                try requestHandler.perform(self.analysisRequests)
            } catch {
                print("Error: Vision request failed with error \(error)")
            }
        }
    }

    fileprivate func resetTranspositionHistory() {
        transpositionHistoryPoints.removeAll()
    }

    fileprivate func recordTransposition(_ point: CGPoint) {
        transpositionHistoryPoints.append(point)

        if transpositionHistoryPoints.count > maximumHistoryLength {
            transpositionHistoryPoints.removeFirst()
        }
    }

    fileprivate func sceneStabilityAchived() -> Bool {
        if transpositionHistoryPoints.count == maximumHistoryLength { // do we have enough evidence
            // calculate the moving average
            var movingAverage: CGPoint = .zero
            for currentPoint in transpositionHistoryPoints {
                movingAverage.x += currentPoint.x
                movingAverage.y += currentPoint.y
            }

            let distance = abs(movingAverage.x) + abs(movingAverage.y)
            if distance < 20 {
                return true
            }
        }

        return false
    }

    fileprivate func showStabilityOverlay(_ visiable: Bool) {
        DispatchQueue.main.async {
            if visiable {
                self.stableLabel.isHidden = false
            } else {
                self.stableLabel.isHidden = true
            }
        }
    }

    fileprivate func configurePreviewLayer() {
        previewLayer.frame = previewView.bounds
        previewLayer.videoGravity = .resizeAspectFill

        let deviceOrientation = UIDevice.current.orientation

        switch deviceOrientation {
        case .landscapeRight:
            previewLayer.connection?.videoOrientation = .landscapeLeft
        case .landscapeLeft:
            previewLayer.connection?.videoOrientation = .landscapeRight
        case .portraitUpsideDown:
            previewLayer.connection?.videoOrientation = .portraitUpsideDown
        default:
            previewLayer.connection?.videoOrientation = .portrait
        }
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        guard previousPixelBuffer != nil else {
            previousPixelBuffer = pixelBuffer
            self.resetTranspositionHistory()
            return
        }

        if barcodeDetected {
            return
        }

        let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: pixelBuffer)

        do {
            try sequenceRequestHandler.perform([registrationRequest], on: previousPixelBuffer!)
        } catch  let error as NSError {
            print("failed to process request \(error.localizedDescription)")
        }

        previousPixelBuffer = pixelBuffer

        if let results = registrationRequest.results {
            if let alignmentObversation = results.first as? VNImageTranslationAlignmentObservation {
                let alignmentTransform = alignmentObversation.alignmentTransform
                self.recordTransposition(CGPoint(x: alignmentTransform.tx, y: alignmentTransform.ty))
            }
        }

        if self.sceneStabilityAchived() {
            showStabilityOverlay(true)

            if currentlyAnalyzedPixelBuffer == nil {
                // Retain the image buffer for Vision processing
                currentlyAnalyzedPixelBuffer = pixelBuffer
                analyzeCurrentImage()
            }
        } else {
            showStabilityOverlay(false)
        }
    }
}
