# Workbench — 119 original USDZ models

101 built-in components, 14 complete frames and 4 standalone airframe parts.

- Metres; +Y up; +Z forward. Motor/propeller axes are local +Y.
- USDZ packages contain USDC meshes and all referenced PBR textures.
- Every asset passes macOS usdchecker --arkit and native SceneKit import.
- Labels are projected onto their host surfaces; drilled panels have real through-holes.
- Support audit flags isolated meshes; independent two-/four-module gear kits are explicit.
- Separate Surveyor S1 and Aquila LC-4 wings/fuselages retain their assembly datum.
- Original representative designs based on the project's catalog dimensions;
  these are display assets, not measured commercial replicas or manufacturing CAD.

The archive contains the ready-to-use USDZ files, manifest and inspection reports.
In the authoring folder beside the archive, open `catalog.html` in a browser to browse the six native-rendered views of every asset.

The application uses `DroneUAVDemo/Resources/Models/WorkbenchParts` through
`WorkbenchModelAssetLibrary`, for both Workbench previews and assembled vehicles.
Custom dimensions/parameters and imported CAD continue to use their authored
procedural/CAD geometry. Materials are copied per instance to isolate highlights.

Rebuild with the bundled Python runtime (numpy/Pillow):

    python3 Tools/WorkbenchAssets/build.py --install
    swiftc -O Tools/WorkbenchAssets/render.swift -o /tmp/workbench-model-render
    /tmp/workbench-model-render Assets/WorkbenchModels/models Assets/WorkbenchModels/previews
    python3 Tools/WorkbenchAssets/publish.py
    bash Tools/WorkbenchAssets/probe.sh

Native render/Swift macro compilation requires system services accessible outside
the Codex command sandbox. No internet, model downloads or external textures are
required. Generator sources live in `Tools/WorkbenchAssets`; USDA and all original
texture maps are preserved in `sources`.
