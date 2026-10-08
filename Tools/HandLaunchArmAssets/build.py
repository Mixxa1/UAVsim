"""Import para's CC0 MakeHuman arms, preserving topology, UVs, and skin weights.

Run in Blender 4.5+: Blender --background --factory-startup --disable-autoexec
  --python Tools/HandLaunchArmAssets/build.py
Native USD tools package the editable skeleton and an open/grip animation.
"""
import hashlib
import json
import math
import shutil
import subprocess
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'Assets/HandLaunchArm'
SOURCE = OUT / 'sources'
ORIGINAL = SOURCE / 'original'
SOURCE_URL = 'https://opengameart.org/content/fps-arms-rigged-only'


def run(args):
    process = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if process.returncode:
        raise RuntimeError(process.stdout + process.stderr)
    return process.stdout + process.stderr


def vector(value):
    return '(' + ', '.join(f'{float(x):.9g}' for x in value) + ')'


def matrix(value):
    return '((1,0,0,0),(0,1,0,0),(0,0,1,0),' + vector([*value, 1]) + ')'


def unit(value):
    return value / np.linalg.norm(value)


def build_side(mesh, arm, side):
    bones = arm.data.bones
    # The FPS source's limb labels use its rotated view-model convention.
    # In our Y-up, fingers-forward frame: palm +Y, left thumb +X, right thumb -X.
    original_side = '.R' if side == 'left' else '.L'
    hand = 'hand' + original_side
    middle = 'f_middle.01' + original_side
    index = 'f_index.01' + original_side
    pinky = 'f_pinky.01' + original_side
    def head(name):
        return np.array(bones[name].head_local[:], dtype=float)
    wrist = head(hand)
    center = (wrist + head(middle)) * 0.5
    z_axis = unit(wrist - head(middle))
    x_axis = head(index) - head(pinky)
    if side == 'right':
        x_axis *= -1
    x_axis = unit(x_axis - z_axis * np.dot(x_axis, z_axis))
    y_axis = unit(np.cross(z_axis, x_axis))
    basis = np.stack([x_axis, y_axis, z_axis])
    scale = 0.11  # Original MakeHuman units; adult arm/hand, fixed for all UAVs.
    def canonical(value):
        return basis @ (np.array(value, dtype=float) - center) * scale

    # Move pivots to the anatomical joints when reversing the arm chain for wrist IK.
    # Original painted weights stay bound to the same named deform regions.
    definitions = [
        ('Palm', -1, hand, center),
        ('Wrist', 0, 'forearm' + original_side, wrist),
        ('Elbow', 1, 'upper_arm' + original_side, head('forearm' + original_side)),
        ('Shoulder', 2, 'deltoid' + original_side, head('upper_arm' + original_side)),
        ('Collar', 3, 'clavicle' + original_side, head('deltoid' + original_side)),
    ]
    digits = []
    for digit in ['index', 'middle', 'ring', 'pinky', 'thumb']:
        parent = 0
        if digit != 'thumb':
            source_name = 'palm_' + digit + original_side
            parent = len(definitions)
            definitions.append((digit + '_metacarpal', 0, source_name, head(source_name)))
        indices = []
        axes = []
        for part, label in enumerate(['proximal', 'middle', 'distal'], 1):
            source_name = (f'thumb.{part:02}' if digit == 'thumb' else f'f_{digit}.{part:02}') + original_side
            current = len(definitions)
            definitions.append((digit + '_' + label, parent, source_name, head(source_name)))
            along = basis @ np.array((bones[source_name].tail_local - bones[source_name].head_local)[:])
            axis = unit(np.cross(along, np.array([0.0, 1.0, 0.0])))
            axes.append(axis.tolist())
            indices.append(current)
            parent = current
        digits.append({'name': digit, 'joints': indices, 'axes': axes})
    group_to_joint = {name: i for i, (_, _, name, _) in enumerate(definitions)}
    positions = np.array([canonical(pos) for _, _, _, pos in definitions])
    local = np.array([pos - positions[parent] if parent >= 0 else pos for pos, (_, parent, _, _) in zip(positions, definitions)])
    paths = []
    for name, parent, _, _ in definitions:
        paths.append((paths[parent] + '/' if parent >= 0 else '') + name)

    # Splitting the two source arms removes only the other arm, never hand detail.
    sign = 1 if original_side == '.L' else -1
    triangles = [t for t in mesh.data.loop_triangles if sign * sum(mesh.data.vertices[v].co.x for v in t.vertices) >= 0]
    source_ids = sorted({v for t in triangles for v in t.vertices})
    vertex_map = {v: i for i, v in enumerate(source_ids)}
    points = np.array([canonical(mesh.data.vertices[i].co[:]) for i in source_ids])
    normals = np.array([basis @ np.array(mesh.data.vertices[i].normal[:]) for i in source_ids])
    faces = np.array([[vertex_map[v] for v in t.vertices] for t in triangles], dtype=int)
    uv = [mesh.data.uv_layers.active.data[loop].uv[:] for t in triangles for loop in t.loops]
    influences = []
    for i in source_ids:
        values = [(group_to_joint[mesh.vertex_groups[g.group].name], g.weight) for g in mesh.data.vertices[i].groups
            if g.weight > 0 and mesh.vertex_groups[g.group].name in group_to_joint]
        if not values:
            raise ValueError(f'Unweighted source vertex: {side} {i}')
        total = sum(w for _, w in values)
        influences.append([(j, w / total) for j, w in values])
    width = max(len(values) for values in influences)
    joint_indices = np.zeros((len(points), width), dtype=int)
    joint_weights = np.zeros((len(points), width), dtype=float)
    for i, values in enumerate(influences):
        for k, (j, w) in enumerate(values):
            joint_indices[i, k] = j
            joint_weights[i, k] = w

    sample_ids = set()
    for digit in digits:
        strength = (joint_weights * np.isin(joint_indices, digit['joints'])).sum(axis=1)
        ids = np.where(strength > 0.55)[0]
        sample_ids.update(ids[::max(1, len(ids) // 40)].tolist())
    ids = np.where((points[:, 2] > -0.045) & (points[:, 2] < 0.04) & (np.abs(points[:, 0]) < 0.07))[0]
    sample_ids.update(ids[::max(1, len(ids) // 80)].tolist())
    rig = {'joints': [{'name': name, 'path': path, 'parent': parent, 'source_bone': source_name,
            'position': pos.tolist(), 'local_position': offset.tolist()}
        for (name, parent, source_name, _), path, pos, offset in zip(definitions, paths, positions, local)],
        'digits': digits, 'vertex_count': len(points), 'triangles': len(faces), 'handedness': side,
        'source_url': SOURCE_URL, 'license': 'CC0-1.0', 'author': 'para / MakeHuman team',
        'influences_per_vertex': width, 'subdivision_level': 2,
        'collision_samples': [{'point': points[i].tolist(), 'indices': joint_indices[i].tolist(), 'weights': joint_weights[i].tolist()} for i in sorted(sample_ids)]}
    (OUT / f'rig-{side}.json').write_text(json.dumps(rig, indent=2) + '\n')
    lines = ['#usda 1.0', '(', '    defaultPrim = "HandLaunchArm"', '    metersPerUnit = 1', '    upAxis = "Y"',
        '    startTimeCode = 0', '    endTimeCode = 120', '    timeCodesPerSecond = 30', ')',
        'def SkelRoot "HandLaunchArm" (kind = "component")', '{',
        '    custom string sourceCredit = "para / MakeHuman team; CC0-1.0; ' + SOURCE_URL + '"',
        '    def Scope "Materials"', '    {', '        def Material "Skin"', '        {',
        '            token outputs:surface.connect = </HandLaunchArm/Materials/Skin/Surface.outputs:surface>',
        '            def Shader "Surface"', '            {', '                uniform token info:id = "UsdPreviewSurface"',
        '                color3f inputs:diffuseColor.connect = </HandLaunchArm/Materials/Skin/Texture.outputs:rgb>',
        '                float inputs:roughness = 0.62', '                float inputs:metallic = 0', '                token outputs:surface', '            }',
        '            def Shader "Texture"', '            {', '                uniform token info:id = "UsdUVTexture"',
        '                asset inputs:file = @source-skin.png@', '                token inputs:sourceColorSpace = "sRGB"',
        '                float2 inputs:st.connect = </HandLaunchArm/Materials/Skin/UV.outputs:result>',
        '                float3 outputs:rgb', '            }',
        '            def Shader "UV"', '            {', '                uniform token info:id = "UsdPrimvarReader_float2"',
        '                string inputs:varname = "st"', '                float2 outputs:result', '            }', '        }', '    }',
        '    def Skeleton "Skeleton" (prepend apiSchemas = ["SkelBindingAPI"])', '    {',
        '        uniform token[] joints = ' + json.dumps(paths),
        '        uniform matrix4d[] bindTransforms = [' + ', '.join(matrix(pos) for pos in positions) + ']',
        '        uniform matrix4d[] restTransforms = [' + ', '.join(matrix(pos) for pos in local) + ']',
        '        rel skel:animationSource = </HandLaunchArm/Animation>', '    }',
        '    def SkelAnimation "Animation"', '    {', '        uniform token[] joints = ' + json.dumps(paths),
        '        float3[] translations = [' + ', '.join(vector(v) for v in local) + ']',
        '        half3[] scales = [' + ', '.join('(1,1,1)' for _ in definitions) + ']']
    samples = []
    for frame in range(121):
        closure = math.sin(math.pi * frame / 120) ** 2
        rotations = [[1, 0, 0, 0] for _ in definitions]
        for digit in digits:
            for part, j in enumerate(digit['joints']):
                angle = closure * math.radians([55, 65, 40][part])
                axis = np.array(digit['axes'][part])
                rotations[j] = [math.cos(angle / 2), *(axis * math.sin(angle / 2))]
        samples.append(f'{frame}: [' + ', '.join(vector(q) for q in rotations) + ']')
    lines += ['        quatf[] rotations.timeSamples = {' + ', '.join(samples) + '}', '    }',
        '    def Mesh "SkinMesh" (prepend apiSchemas = ["SkelBindingAPI", "MaterialBindingAPI"])', '    {',
        '        uniform token subdivisionScheme = "none"', '        bool doubleSided = false',
        '        point3f[] points = [' + ', '.join(vector(v) for v in points) + ']',
        '        normal3f[] normals = [' + ', '.join(vector(v) for v in normals) + '] (interpolation = "vertex")',
        '        int[] faceVertexCounts = [' + ', '.join('3' for _ in faces) + ']',
        '        int[] faceVertexIndices = [' + ', '.join(str(int(v)) for v in faces.ravel()) + ']',
        '        texCoord2f[] primvars:st = [' + ', '.join(vector(v) for v in uv) + '] (interpolation = "faceVarying")',
        '        rel material:binding = </HandLaunchArm/Materials/Skin>',
        '        rel skel:skeleton = </HandLaunchArm/Skeleton>',
        '        matrix4d primvars:skel:geomBindTransform = ' + matrix([0, 0, 0]),
        '        int[] primvars:skel:jointIndices = [' + ', '.join(str(int(v)) for v in joint_indices.ravel()) + '] (\n            interpolation = "vertex"\n            elementSize = ' + str(width) + '\n        )',
        '        float[] primvars:skel:jointWeights = [' + ', '.join(f'{float(v):.9g}' for v in joint_weights.ravel()) + '] (\n            interpolation = "vertex"\n            elementSize = ' + str(width) + '\n        )',
        '    }', '}']
    usda = SOURCE / f'hand-launch-arm-{side}.usda'
    usda.write_text('\n'.join(lines) + '\n')
    binary = SOURCE / f'hand-launch-arm-{side}.usdc'
    run(['/usr/bin/usdcat', usda, '-o', binary])
    asset = OUT / f'hand-launch-arm-{side}.usdz'
    run(['/usr/bin/usdzip', '--arkitAsset', binary, asset])
    (OUT / f'usdchecker-{side}.txt').write_text(run(['/usr/bin/usdchecker', '--arkit', asset]))
    return {'handedness': side, 'file': asset.name, 'rig': f'rig-{side}.json',
        'vertices': len(points), 'triangles': len(faces), 'joints': len(definitions),
        'influences_per_vertex': width, 'sha256': hashlib.sha256(asset.read_bytes()).hexdigest()}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    SOURCE.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ORIGINAL / 'new_diff.png', SOURCE / 'source-skin.png')
    bpy.ops.wm.open_mainfile(filepath=str(ORIGINAL / 'FPS ARMS RIG 1.blend'), use_scripts=False)
    arm = next(o for o in bpy.data.objects if o.type == 'ARMATURE')
    mesh = next(o for o in bpy.data.objects if o.type == 'MESH')
    arm.data.pose_position = 'REST'
    arm.animation_data_clear()
    for bone in arm.pose.bones:
        bone.matrix_basis = Matrix.Identity(4)
    original_count = len(mesh.data.vertices)
    # Refine the original anatomical surface; never decimate or unsubdivide it.
    sub = mesh.modifiers.new('Anatomical surface subdivision', 'SUBSURF')
    sub.levels = 2
    sub.render_levels = 2
    bpy.context.view_layer.objects.active = mesh
    bpy.ops.object.modifier_move_up(modifier=sub.name)
    bpy.ops.object.modifier_apply(modifier=sub.name)
    for polygon in mesh.data.polygons:
        polygon.use_smooth = True
    mesh.data.calc_loop_triangles()
    assert len(mesh.data.vertices) > original_count
    assets = [build_side(mesh, arm, side) for side in ('left', 'right')]
    manifest = {'schema_version': 1, 'source_url': SOURCE_URL, 'author': 'para / MakeHuman team',
        'license': 'CC0-1.0', 'license_url': 'https://creativecommons.org/publicdomain/zero/1.0/',
        'original_vertices': original_count, 'subdivision_level': 2, 'geometry_reduction': False,
        'original_skin_texture': [1024, 1024], 'assets': assets}
    (OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('FREE_HUMAN_ARMS', json.dumps(manifest))


if __name__ == '__main__':
    main()
