import FlutterMacOS
import Metal

final class PreciseReferenceImageProcessor {
  private struct Vertex {
    var position: SIMD2<Float>
  }

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let sampler: MTLSamplerState
  private let vertexBuffer: MTLBuffer

  static func register(with controller: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "casrand_forge/precise_reference",
      binaryMessenger: controller.engine.binaryMessenger
    )
    guard let processor = PreciseReferenceImageProcessor() else {
      channel.setMethodCallHandler { _, result in
        result(FlutterError(
          code: "metal_unavailable",
          message: "Metal is unavailable for Precise Reference processing.",
          details: nil
        ))
      }
      return
    }
    channel.setMethodCallHandler(processor.handle)
  }

  private init?() {
    guard let device = MTLCreateSystemDefaultDevice(),
          let commandQueue = device.makeCommandQueue() else {
      return nil
    }

    let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
      float2 position;
    };

    struct VertexOut {
      float4 position [[position]];
    };

    struct Parameters {
      float2 sourceSize;
      float2 targetSize;
      float2 drawSize;
      float2 offset;
    };

    vertex VertexOut vertex_main(
      const device VertexIn* vertices [[buffer(0)]],
      uint id [[vertex_id]]
    ) {
      VertexOut output;
      output.position = float4(vertices[id].position, 0.0, 1.0);
      return output;
    }

    fragment float4 fragment_main(
      VertexOut input [[stage_in]],
      texture2d<float> image [[texture(0)]],
      sampler imageSampler [[sampler(0)]],
      constant Parameters& parameters [[buffer(0)]]
    ) {
      const float2 pixel = input.position.xy;
      const float2 end = parameters.offset + parameters.drawSize;

      if (pixel.x <= parameters.offset.x || pixel.y <= parameters.offset.y ||
          pixel.x > end.x || pixel.y > end.y) {
        return float4(0.0);
      }

      float coverage = 1.0;
      if (pixel.x == end.x) {
        coverage *= 0.5;
      }
      if (pixel.y == end.y) {
        coverage *= 0.5;
      }

      const float2 scale = parameters.sourceSize / parameters.drawSize;
      const float2 sourceCoordinate = fma(
        pixel,
        scale,
        -parameters.offset * scale
      );
      const float2 textureCoordinate =
        sourceCoordinate / parameters.sourceSize;
      return image.sample(imageSampler, textureCoordinate) * coverage;
    }
    """

    do {
      let library = try device.makeLibrary(source: shaderSource, options: nil)
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
      descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
      descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
      descriptor.colorAttachments[0].isBlendingEnabled = true
      descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
      descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
      descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      return nil
    }

    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .linear
    samplerDescriptor.magFilter = .linear
    samplerDescriptor.sAddressMode = .clampToEdge
    samplerDescriptor.tAddressMode = .clampToEdge
    samplerDescriptor.normalizedCoordinates = true

    let vertices = [
      Vertex(position: SIMD2(-1, 1)),
      Vertex(position: SIMD2(-1, -1)),
      Vertex(position: SIMD2(1, 1)),
      Vertex(position: SIMD2(1, -1)),
    ]
    guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor),
          let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<Vertex>.stride * vertices.count,
            options: .storageModeShared
          ) else {
      return nil
    }

    self.device = device
    self.commandQueue = commandQueue
    self.sampler = sampler
    self.vertexBuffer = vertexBuffer
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "processImage" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let arguments = call.arguments as? [String: Any],
          let typedPixels = arguments["sourcePixels"] as? FlutterStandardTypedData,
          let sourceWidth = arguments["sourceWidth"] as? Int,
          let sourceHeight = arguments["sourceHeight"] as? Int,
          let targetWidth = arguments["targetWidth"] as? Int,
          let targetHeight = arguments["targetHeight"] as? Int,
          let drawWidth = arguments["drawWidth"] as? Int,
          let drawHeight = arguments["drawHeight"] as? Int,
          let offsetX = arguments["offsetX"] as? Double,
          let offsetY = arguments["offsetY"] as? Double else {
      result(FlutterError(
        code: "invalid_arguments",
        message: "Invalid Precise Reference image parameters.",
        details: nil
      ))
      return
    }

    do {
      let output = try process(
        pixels: typedPixels.data,
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        drawWidth: drawWidth,
        drawHeight: drawHeight,
        offsetX: Float(offsetX),
        offsetY: Float(offsetY)
      )
      result(FlutterStandardTypedData(bytes: output))
    } catch {
      result(FlutterError(
        code: "processing_failed",
        message: error.localizedDescription,
        details: nil
      ))
    }
  }

  private func process(
    pixels: Data,
    sourceWidth: Int,
    sourceHeight: Int,
    targetWidth: Int,
    targetHeight: Int,
    drawWidth: Int,
    drawHeight: Int,
    offsetX: Float,
    offsetY: Float
  ) throws -> Data {
    guard sourceWidth > 0, sourceHeight > 0,
          targetWidth > 0, targetHeight > 0,
          drawWidth > 0, drawHeight > 0,
          pixels.count == sourceWidth * sourceHeight * 4 else {
      throw ProcessorError.invalidPixelData
    }

    var premultipliedPixels = [UInt8](pixels)
    for index in stride(from: 0, to: premultipliedPixels.count, by: 4) {
      let alpha = Int(premultipliedPixels[index + 3])
      for channel in 0..<3 {
        let product = Int(premultipliedPixels[index + channel]) * alpha
        let rounded = product + 128
        premultipliedPixels[index + channel] = UInt8(
          (rounded + (rounded >> 8)) >> 8
        )
      }
    }

    let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: sourceWidth,
      height: sourceHeight,
      mipmapped: false
    )
    sourceDescriptor.usage = .shaderRead
    guard let sourceTexture = device.makeTexture(descriptor: sourceDescriptor) else {
      throw ProcessorError.textureCreationFailed
    }
    premultipliedPixels.withUnsafeBytes { bytes in
      sourceTexture.replace(
        region: MTLRegionMake2D(0, 0, sourceWidth, sourceHeight),
        mipmapLevel: 0,
        withBytes: bytes.baseAddress!,
        bytesPerRow: sourceWidth * 4
      )
    }

    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm,
      width: targetWidth,
      height: targetHeight,
      mipmapped: false
    )
    targetDescriptor.usage = .renderTarget
    targetDescriptor.storageMode = .shared
    guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
      throw ProcessorError.textureCreationFailed
    }

    var parameters: [Float] = [
      Float(sourceWidth), Float(sourceHeight),
      Float(targetWidth), Float(targetHeight),
      Float(drawWidth), Float(drawHeight),
      offsetX, offsetY,
    ]
    guard let parameterBuffer = device.makeBuffer(
      bytes: &parameters,
      length: MemoryLayout<Float>.stride * parameters.count,
      options: .storageModeShared
    ), let commandBuffer = commandQueue.makeCommandBuffer() else {
      throw ProcessorError.commandCreationFailed
    }

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = targetTexture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(
      red: 0,
      green: 0,
      blue: 0,
      alpha: 1
    )
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw ProcessorError.commandCreationFailed
    }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setFragmentTexture(sourceTexture, index: 0)
    encoder.setFragmentSamplerState(sampler, index: 0)
    encoder.setFragmentBuffer(parameterBuffer, offset: 0, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if commandBuffer.status == .error {
      throw commandBuffer.error ?? ProcessorError.commandExecutionFailed
    }

    var output = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
    output.withUnsafeMutableBytes { bytes in
      targetTexture.getBytes(
        bytes.baseAddress!,
        bytesPerRow: targetWidth * 4,
        from: MTLRegionMake2D(0, 0, targetWidth, targetHeight),
        mipmapLevel: 0
      )
    }
    return Data(output)
  }

  private enum ProcessorError: LocalizedError {
    case invalidPixelData
    case textureCreationFailed
    case commandCreationFailed
    case commandExecutionFailed

    var errorDescription: String? {
      switch self {
      case .invalidPixelData:
        return "Invalid Precise Reference pixel data."
      case .textureCreationFailed:
        return "Unable to create a Metal texture."
      case .commandCreationFailed:
        return "Unable to create Metal rendering commands."
      case .commandExecutionFailed:
        return "Metal rendering failed."
      }
    }
  }
}
