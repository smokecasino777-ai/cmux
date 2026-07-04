import Foundation

/// Settings under the dotted-id prefix `backdrop.*`.
public struct BackdropCatalogSection: SettingCatalogSection {
    /// Absolute or `~`-relative path to a compiled Metal (`.metal`) shader
    /// source rendered as the animated window backdrop. Empty disables the
    /// shader backdrop. Compile Shadertoy-style GLSL shaders with
    /// `scripts/compile-backdrop-shader.sh`.
    public let shaderPath = DefaultsKey<String>(
        id: "backdrop.shaderPath",
        defaultValue: "",
        userDefaultsKey: "backdropShaderPath"
    )

    public init() {}
}
