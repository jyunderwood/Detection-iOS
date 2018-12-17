import AVFoundation
import UIKit
import Vision

class ViewController: UIViewController {
    var captureSession = AVCaptureSession()
    var previewLayer = AVCaptureVideoPreviewLayer()

    var requests = [VNRequest]()

    @IBOutlet var previewView: UIImageView!
    @IBOutlet var barcodeValueLabel: UILabel!

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startLivePreview()
        startBarcodeDetection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession.stopRunning()
    }

    override func viewDidLayoutSubviews() {
        configurePreviewLayer()
    }

    func startLivePreview() {
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

    func startBarcodeDetection() {
        let barcodeRequest = VNDetectBarcodesRequest(completionHandler: detectBarcodeHandler)
        requests = [barcodeRequest]
    }

    func detectBarcodeHandler(request: VNRequest, error: Error?) {
        if error != nil {
            print(error!)
        }

        guard let observations = request.results as? [VNBarcodeObservation] else {
            print("Unexpected result type. Expecting VNBarcodeObservation.")
            return
        }

        guard observations.first != nil else {
            return
        }

        DispatchQueue.main.async {
            for barcode in observations {
                self.barcodeValueLabel.text = barcode.payloadStringValue
            }
        }
    }

    private func configurePreviewLayer() {
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

        var requestOptions: [VNImageOption: Any] = [:]

        if let camData = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix, attachmentModeOut: nil) {
            requestOptions = [.cameraIntrinsics: camData]
        }

        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: requestOptions)

        do {
            try imageRequestHandler.perform(requests)
        } catch {
            print(error)
        }
    }
}
