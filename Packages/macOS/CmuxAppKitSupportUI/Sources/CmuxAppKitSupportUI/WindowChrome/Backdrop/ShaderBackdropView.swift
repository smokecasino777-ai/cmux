public import SwiftUI
public import AppKit
import Metal
import QuartzCore
import os

/// Renders a Shadertoy-style fragment shader (pre-translated to Metal
/// Shading Language by `scripts/compile-backdrop-shader.sh`) as an animated
/// backdrop for the `windowRoot` chrome role.
///
/// Isolation contract (see CLAUDE.md pitfalls): this never touches Ghostty
/// surfaces or their render loop. Per-frame work is one fullscreen-triangle
/// encode on a pre-built pipeline; the display link pauses while the window
/// is occluded and renders a single static frame under Reduce Motion. Any
/// load/compile failure degrades to rendering nothing, leaving the flat
/// backdrop color behind this view visible.
public struct ShaderBackdropView: NSViewRepresentable {
    private let shaderPath: String
    private let baseColor: NSColor
    private let opacity: CGFloat

    /// Creates a shader backdrop for a compiled `.metal` source file path.
    public init(shaderPath: String, baseColor: NSColor, opacity: CGFloat) {
        self.shaderPath = shaderPath
        self.baseColor = baseColor
        self.opacity = opacity
    }

    public func makeNSView(context: Context) -> ShaderBackdropNSView {
        ShaderBackdropNSView(shaderPath: shaderPath, baseColor: baseColor, opacity: opacity)
    }

    public func updateNSView(_ nsView: ShaderBackdropNSView, context: Context) {
        nsView.update(shaderPath: shaderPath, baseColor: baseColor, opacity: opacity)
    }
}

/// AppKit host view owning the `CAMetalLayer` and display link.
public final class ShaderBackdropNSView: NSView {
    private static let logger = Logger(subsystem: "com.cmux.shader-backdrop", category: "renderer")

    // Byte layout of Ghostty's std140 `Globals` uniform block from
    // `src/renderer/shaders/shadertoy_prefix.glsl`. Only the fields the
    // backdrop animates are written; the rest stay zero.
    private enum GlobalsLayout {
        static let resolutionOffset = 0      // vec3 iResolution
        static let timeOffset = 12           // float iTime
        static let backgroundColorOffset = 4400  // vec3 iBackgroundColor
        static let foregroundColorOffset = 4416  // vec3 iForegroundColor
        static let length = 4608             // padded struct size
    }

    private let metalLayer = CAMetalLayer()
    private var device: (any MTLDevice)?
    private var commandQueue: (any MTLCommandQueue)?
    private var pipelineState: (any MTLRenderPipelineState)?
    private var globalsBuffer: (any MTLBuffer)?
    private var channelTexture: (any MTLTexture)?
    private var samplerState: (any MTLSamplerState)?
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = CACurrentMediaTime()

    private var shaderPath: String
    private var baseColor: NSColor
    private var opacity: CGFloat
    private var loadedShaderPath: String?

    init(shaderPath: String, baseColor: NSColor, opacity: CGFloat) {
        self.shaderPath = shaderPath
        self.baseColor = baseColor
        self.opacity = opacity
        super.init(frame: .zero)
        wantsLayer = true
        layer = metalLayer
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        setUpMetal()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Applies new settings, rebuilding the pipeline only when the path changed.
    func update(shaderPath: String, baseColor: NSColor, opacity: CGFloat) {
        let colorChanged = baseColor != self.baseColor || opacity != self.opacity
        self.baseColor = baseColor
        self.opacity = opacity
        if shaderPath != self.shaderPath || pipelineState == nil {
            self.shaderPath = shaderPath
            setUpMetal()
        } else if colorChanged {
            updateChannelTexture()
            updateStaticUniforms()
        }
    }

    // MARK: Lifecycle

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopDisplayLink() : startDisplayLinkIfNeeded()
        if window != nil {
            updateDrawableSize()
            renderFrame()
        }
    }

    override public func layout() {
        super.layout()
        updateDrawableSize()
    }

    override public func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    // No deinit invalidation needed: the NSView `displayLink(target:selector:)`
    // API references its target weakly, and `viewDidMoveToWindow` stops the
    // link whenever the view leaves a window.

    // MARK: Metal setup

    private func setUpMetal() {
        pipelineState = nil
        guard !shaderPath.isEmpty else { return }
        let expandedPath = (shaderPath as NSString).expandingTildeInPath
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            Self.logger.warning("no Metal device; shader backdrop disabled")
            return
        }
        self.device = device
        if commandQueue == nil { commandQueue = device.makeCommandQueue() }

        guard let source = try? String(contentsOfFile: expandedPath, encoding: .utf8) else {
            Self.logger.warning("shader backdrop source unreadable: \(expandedPath, privacy: .public)")
            return
        }

        do {
            let fragmentLibrary = try device.makeLibrary(source: source, options: nil)
            let vertexLibrary = try device.makeLibrary(source: Self.vertexSource, options: nil)
            guard let fragment = fragmentLibrary.makeFunction(name: "main0"),
                  let vertex = vertexLibrary.makeFunction(name: "backdrop_vertex") else {
                Self.logger.warning("shader backdrop missing entry points: \(expandedPath, privacy: .public)")
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = metalLayer.pixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Self.logger.warning("shader backdrop compile failed: \(String(describing: error), privacy: .public)")
            return
        }

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        samplerState = device.makeSamplerState(descriptor: sampler)
        globalsBuffer = device.makeBuffer(length: GlobalsLayout.length, options: .storageModeShared)
        if let buffer = globalsBuffer {
            memset(buffer.contents(), 0, GlobalsLayout.length)
        }
        updateChannelTexture()
        updateStaticUniforms()
        loadedShaderPath = expandedPath
        startTime = CACurrentMediaTime()
        startDisplayLinkIfNeeded()
    }

    /// iChannel0 is a 1×1 texture holding the terminal base color, so
    /// shaders that sample "the terminal" blend over the theme color and
    /// alpha-preserving shaders keep the configured opacity.
    private func updateChannelTexture() {
        guard let device else { return }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return }
        let rgb = baseColor.usingColorSpace(.sRGB) ?? baseColor
        var pixel: [UInt8] = [
            UInt8(max(0, min(255, rgb.redComponent * 255))),
            UInt8(max(0, min(255, rgb.greenComponent * 255))),
            UInt8(max(0, min(255, rgb.blueComponent * 255))),
            UInt8(max(0, min(255, opacity * 255))),
        ]
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: &pixel, bytesPerRow: 4
        )
        channelTexture = texture
    }

    private func updateStaticUniforms() {
        guard let buffer = globalsBuffer else { return }
        let rgb = baseColor.usingColorSpace(.sRGB) ?? baseColor
        var bg: (Float, Float, Float) = (Float(rgb.redComponent), Float(rgb.greenComponent), Float(rgb.blueComponent))
        var fg: (Float, Float, Float) = (1 - bg.0, 1 - bg.1, 1 - bg.2)
        memcpy(buffer.contents() + GlobalsLayout.backgroundColorOffset, &bg, 12)
        memcpy(buffer.contents() + GlobalsLayout.foregroundColorOffset, &fg, 12)
    }

    // MARK: Display link

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil, window != nil, pipelineState != nil else { return }
        guard !reduceMotion else {
            renderFrame()
            return
        }
        let link = displayLink(target: self, selector: #selector(displayLinkFired))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayLinkFired() {
        guard let window, window.occlusionState.contains(.visible) else { return }
        if reduceMotion {
            stopDisplayLink()
            return
        }
        renderFrame()
    }

    private func updateDrawableSize() {
        guard let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    // MARK: Rendering

    private func renderFrame() {
        guard let pipelineState, let commandQueue, let buffer = globalsBuffer,
              metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable() else { return }

        var resolution: (Float, Float, Float) = (
            Float(metalLayer.drawableSize.width), Float(metalLayer.drawableSize.height), 1
        )
        var time = Float(CACurrentMediaTime() - startTime)
        memcpy(buffer.contents() + GlobalsLayout.resolutionOffset, &resolution, 12)
        memcpy(buffer.contents() + GlobalsLayout.timeOffset, &time, 4)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        if let channelTexture { encoder.setFragmentTexture(channelTexture, index: 0) }
        if let samplerState { encoder.setFragmentSamplerState(samplerState, index: 0) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private static let vertexSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VSOut { float4 position [[position]]; };
    vertex VSOut backdrop_vertex(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        VSOut out;
        out.position = float4(pos[vid], 0.0, 1.0);
        return out;
    }
    """
}
