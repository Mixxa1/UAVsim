import SceneKit

/// Real optical blur for fog/smog. `scene.fogColor`/the weather envelope sphere only recolor
/// pixels with distance — verified twice (offscreen `SCNRenderer` and a live `SCNView`) that
/// `SCNCamera.wantsDepthOfField` produces zero visible blur in this SceneKit/macOS build even at
/// extreme settings (fStop 0.5, focalLength 135mm) — a known, long-standing SceneKit limitation,
/// not a tuning problem. This is a from-scratch two-pass `SCNTechnique`: pass 1 renders the scene
/// normally into an offscreen color+depth target, pass 2 is a full-screen quad that blurs pass 1's
/// color by a depth-distance-from-focus amount (`WeatherDepthOfField.metal`).
enum WeatherDepthOfFieldTechnique {
    static let shared: SCNTechnique? = SCNTechnique(dictionary: techniqueDictionary)

    private static let techniqueDictionary: [String: Any] = [
        "targets": [
            "weatherDOFColor": ["type": "color"],
            "weatherDOFDepth": ["type": "depth"]
        ],
        "passes": [
            "weatherDOFScenePass": [
                "draw": "DRAW_SCENE",
                "outputs": ["COLOR": "weatherDOFColor", "DEPTH": "weatherDOFDepth"]
            ],
            "weatherDOFBlurPass": [
                "draw": "DRAW_QUAD",
                "metalVertexShader": "weatherDOFVertex",
                "metalFragmentShader": "weatherDOFFragment",
                "inputs": [
                    "sceneColor": "weatherDOFColor",
                    "sceneDepth": "weatherDOFDepth"
                ],
                "outputs": ["COLOR": "COLOR"]
            ]
        ],
        "sequence": ["weatherDOFScenePass", "weatherDOFBlurPass"],
        "symbols": [
            "sceneColor": ["type": "sampler2D"],
            "sceneDepth": ["type": "sampler2D"]
        ]
    ]
}
