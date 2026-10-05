# Simulated LWIR rendering

The thermal camera renders a separate category of SceneKit geometry. Visible-light materials,
textures and cameras remain intact. Native and imported surfaces use the same Metal surface
modifier and the same display range/colour ramp as the legend.

## Surface and sensor model

- Temperature follows the live world clock and weather. A material-specific response combines
  present sunlight with irradiance two and four hours earlier, approximating heat storage.
  Surface normals distinguish sun-facing walls, shaded walls and roofs. This is a deterministic
  approximation, including after replay seeks; it does not solve transient heat conduction.
- Emitted and reflected radiance are combined at a representative wavelength of 10 µm, then
  converted to brightness temperature. Glass has high normal-incidence LWIR emissivity and
  stronger reflection at grazing angles. Painted metal differs from masonry.
- Reflections use a sky/ground hemisphere model. Clear sky is colder than cloud cover.
  Distance, rain and fog attenuate radiance toward the air temperature. This is not a calibrated
  radiometric measurement or a full spectral/path-tracing renderer.
- Imported city facades have a shared semantic glazing mask aligned to their existing world-scale
  UVs. Windows, mullions and roof slots remain distinct. Photogrammetric imagery without material
  metadata uses conservative colour/orientation hints; visible RGB is not treated as temperature.
- Stable world-space patches add small residual variation. They are not time-dependent and do
  not replace the temperature model. All palettes display the same temperature field.
- A scene population of materials/orientations determines the display range. Sky is excluded;
  panning does not alter exposure. The range can contract as the scene cools and settles over
  1.5 seconds instead of jumping. Warm mission targets remain within it.

## Cost limits

No CPU readback or per-building image conversion is used. The city adds one cached 256-pixel
glazing mask per facade class. Proxy geometry shares source buffers and retains every material
slot. Discovery is limited to 96 node visits, 32 additions or 4 ms per refresh, with at most
5,200 proxies. Uniform changes use a FIFO with at most 64 materials or 3 ms per refresh;
continuous clock/weather changes cannot starve older entries. Five-minute simulated clock
steps avoid per-frame material rebinding. Evicted streamed tiles release their cached materials.

## Validation

Run `bash Tools/ReplayWorldProbe/run.sh` on a Mac with Metal. It checks CPU/GPU radiance agreement,
sun/shade contrast, glass reflections, weather cooling, retained evening heat, exposure settling,
all three colour ramps, stable aperiodic patches, streamed geometry eviction and bounded work
on a 6,000-mesh map. It also produces city previews using the production building geometry,
facade textures and thermal materials in the temporary `uavsim-thermal-realism` directory.
Glazing checks sample actual rendered pixels, including a scaled facade texture; metadata alone
does not prove that a shader flag or mask reached Metal. Related scalars are packed into vector
arguments to leave space within Metal's buffer-slot limit.
Position-only geometry has a texture-free shader path and recovers normals from GPU derivatives;
the probe verifies that meshes without UV/normal sources still draw valid opaque pixels.

Example test renders (production geometry/materials, a small synthetic layout rather than a
capture of the running user's map): [day, iron](thermal-previews/day-iron.png),
[day, white hot](thermal-previews/day-white.png), [night](thermal-previews/night-iron.png),
[rain](thermal-previews/rain-iron.png). Each weather case uses its own automatic display range;
colours across different cases therefore do not imply equal temperatures.

## References and reuse

- [ThRend](https://github.com/jpaguerre/ThRend) and its
  [Building Simulation 2021 paper](https://publications.ibpsa.org/proceedings/bs/2021/papers/bs2021_30435.pdf)
  are useful references for angular emissivity, emitted/reflected radiance and sky reflections.
  ThRend is an offline C++/Embree renderer consuming precomputed temperatures. The published
  source contains Windows dependencies. An explicit licence for the repository's own source
  was not found during inspection. No ThRend source, executable or dependency is incorporated;
  the simulator implements the physical principles independently in its existing Metal path.
- [FLIR measurement guidance](https://docs.flir.com/T559954/en-US/latest/s12.html#s12s03s02)
  describes the effect of range, emissivity, reflected temperature and atmosphere on a thermogram.
- [FLIR on glass and reflective materials](https://www.flir.com/en-gb/discover/home-outdoor/can-thermal-imaging-see-through-walls/)
  explains why an LWIR image of windows is not a view of the room behind them.

Weather history, occupancy/HVAC, exact material properties for scanned meshes, inter-building
solar occlusion and reflections of individual surrounding objects are not resolved by this model.
They require additional scene data; random gradients cannot recover that data.
