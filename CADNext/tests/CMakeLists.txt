add_executable(cadnext_test_document
    test_document.cpp
)

target_link_libraries(cadnext_test_document
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_stub_kernel
    test_stub_kernel.cpp
)

target_link_libraries(cadnext_test_stub_kernel
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_bridge_export
    test_bridge_export.cpp
)

target_link_libraries(cadnext_test_bridge_export
    PRIVATE
        cadnext_bridge
)

add_executable(cadnext_test_uavpart_format
    test_uavpart_format.cpp
)

target_link_libraries(cadnext_test_uavpart_format
    PRIVATE
        cadnext_bridge
)

add_executable(cadnext_test_primitive_object
    test_primitive_object.cpp
)

target_link_libraries(cadnext_test_primitive_object
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_document_editing
    test_document_editing.cpp
)

target_link_libraries(cadnext_test_document_editing
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_document_serialization
    test_document_serialization.cpp
)

target_link_libraries(cadnext_test_document_serialization
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_command_stack
    test_command_stack.cpp
)

target_link_libraries(cadnext_test_command_stack
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_geometry_evaluator_fallback
    test_geometry_evaluator_fallback.cpp
)

target_link_libraries(cadnext_test_geometry_evaluator_fallback
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_sketch_model
    test_sketch_model.cpp
)

target_link_libraries(cadnext_test_sketch_model
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_workplane_model
    test_workplane_model.cpp
)

target_link_libraries(cadnext_test_workplane_model
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_reference
    test_sketch_reference.cpp
)

target_link_libraries(cadnext_test_sketch_reference
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_serialization
    test_sketch_serialization.cpp
)

target_link_libraries(cadnext_test_sketch_serialization
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_profile_detector
    test_sketch_profile_detector.cpp
)

target_link_libraries(cadnext_test_sketch_profile_detector
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_custom_profile_stability
    test_custom_profile_stability.cpp
)

target_link_libraries(cadnext_test_custom_profile_stability
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_snap
    test_sketch_snap.cpp
)

target_link_libraries(cadnext_test_sketch_snap
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_units_mm_format
    test_units_mm_format.cpp
)

target_link_libraries(cadnext_test_units_mm_format
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_dimension_measurements
    test_sketch_dimension_measurements.cpp
)

target_link_libraries(cadnext_test_sketch_dimension_measurements
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_plane_mapping
    test_sketch_plane_mapping.cpp
)

target_link_libraries(cadnext_test_sketch_plane_mapping
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_reference_projection
    test_sketch_reference_projection.cpp
)

target_link_libraries(cadnext_test_sketch_reference_projection
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_workplane_visibility_policy
    test_workplane_visibility_policy.cpp
)

target_link_libraries(cadnext_test_workplane_visibility_policy
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch2d_view_state
    test_sketch2d_view_state.cpp
)

target_link_libraries(cadnext_test_sketch2d_view_state
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_camera_navigation_state
    test_camera_navigation_state.cpp
)

target_link_libraries(cadnext_test_camera_navigation_state
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_escape_navigation_policy
    test_escape_navigation_policy.cpp
)

target_link_libraries(cadnext_test_escape_navigation_policy
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_view_bounds_policy
    test_view_bounds_policy.cpp
)

target_link_libraries(cadnext_test_view_bounds_policy
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_camera_focus_target
    test_camera_focus_target.cpp
)

target_link_libraries(cadnext_test_camera_focus_target
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_sketch_reference_mapping
    test_sketch_reference_mapping.cpp
)

target_link_libraries(cadnext_test_sketch_reference_mapping
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_extrude_parameters
    test_extrude_parameters.cpp
)

target_link_libraries(cadnext_test_extrude_parameters
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_extrude_direction
    test_extrude_direction.cpp
)

target_link_libraries(cadnext_test_extrude_direction
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_extrude_serialization
    test_extrude_serialization.cpp
)

target_link_libraries(cadnext_test_extrude_serialization
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_extrude_cut_parameters
    test_extrude_cut_parameters.cpp
)

target_link_libraries(cadnext_test_extrude_cut_parameters
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_extrude_cut_depth_modes
    test_extrude_cut_depth_modes.cpp
)

target_link_libraries(cadnext_test_extrude_cut_depth_modes
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_chamfer_parameters
    test_chamfer_parameters.cpp
)

target_link_libraries(cadnext_test_chamfer_parameters
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_fillet_parameters
    test_fillet_parameters.cpp
)

target_link_libraries(cadnext_test_fillet_parameters
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_face_reference
    test_face_reference.cpp
)

target_link_libraries(cadnext_test_face_reference
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_edge_reference
    test_edge_reference.cpp
)

target_link_libraries(cadnext_test_edge_reference
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_edge_reference_refresh
    test_edge_reference_refresh.cpp
)

target_link_libraries(cadnext_test_edge_reference_refresh
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_face_mesh_ownership
    test_face_mesh_ownership.cpp
)

target_link_libraries(cadnext_test_face_mesh_ownership
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_procedural_prism_face_ids
    test_procedural_prism_face_ids.cpp
)

target_link_libraries(cadnext_test_procedural_prism_face_ids
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_face_sketch_reference
    test_face_sketch_reference.cpp
)

target_link_libraries(cadnext_test_face_sketch_reference
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_face_selection_resolution
    test_face_selection_resolution.cpp
)

target_link_libraries(cadnext_test_face_selection_resolution
    PRIVATE
        cadnext_core
)

add_executable(cadnext_test_body_face_selection_state
    test_body_face_selection_state.cpp
)

target_link_libraries(cadnext_test_body_face_selection_state
    PRIVATE
        cadnext_kernel
)

add_executable(cadnext_test_face_workplane_serialization
    test_face_workplane_serialization.cpp
)

target_link_libraries(cadnext_test_face_workplane_serialization
    PRIVATE
        cadnext_core
)

add_test(NAME cadnext_test_sketch_model COMMAND cadnext_test_sketch_model)
add_test(NAME cadnext_test_units_mm_format COMMAND cadnext_test_units_mm_format)
add_test(NAME cadnext_test_sketch_dimension_measurements
         COMMAND cadnext_test_sketch_dimension_measurements)
add_test(NAME cadnext_test_sketch_snap COMMAND cadnext_test_sketch_snap)
add_test(NAME cadnext_test_sketch_plane_mapping COMMAND cadnext_test_sketch_plane_mapping)
add_test(NAME cadnext_test_sketch_reference_projection
         COMMAND cadnext_test_sketch_reference_projection)
add_test(NAME cadnext_test_workplane_visibility_policy
         COMMAND cadnext_test_workplane_visibility_policy)
add_test(NAME cadnext_test_sketch2d_view_state COMMAND cadnext_test_sketch2d_view_state)
add_test(NAME cadnext_test_camera_navigation_state
         COMMAND cadnext_test_camera_navigation_state)
add_test(NAME cadnext_test_escape_navigation_policy
         COMMAND cadnext_test_escape_navigation_policy)
add_test(NAME cadnext_test_view_bounds_policy COMMAND cadnext_test_view_bounds_policy)
add_test(NAME cadnext_test_camera_focus_target COMMAND cadnext_test_camera_focus_target)
add_test(NAME cadnext_test_sketch_reference_mapping
         COMMAND cadnext_test_sketch_reference_mapping)
add_test(NAME cadnext_test_extrude_parameters COMMAND cadnext_test_extrude_parameters)
add_test(NAME cadnext_test_extrude_direction COMMAND cadnext_test_extrude_direction)
add_test(NAME cadnext_test_extrude_serialization
         COMMAND cadnext_test_extrude_serialization)
add_test(NAME cadnext_test_extrude_cut_parameters
         COMMAND cadnext_test_extrude_cut_parameters)
add_test(NAME cadnext_test_extrude_cut_depth_modes
         COMMAND cadnext_test_extrude_cut_depth_modes)
add_test(NAME cadnext_test_chamfer_parameters
         COMMAND cadnext_test_chamfer_parameters)
add_test(NAME cadnext_test_fillet_parameters
         COMMAND cadnext_test_fillet_parameters)
add_test(NAME cadnext_test_face_reference COMMAND cadnext_test_face_reference)
add_test(NAME cadnext_test_edge_reference COMMAND cadnext_test_edge_reference)
add_test(NAME cadnext_test_edge_reference_refresh
         COMMAND cadnext_test_edge_reference_refresh)
add_test(NAME cadnext_test_face_mesh_ownership
         COMMAND cadnext_test_face_mesh_ownership)
add_test(NAME cadnext_test_procedural_prism_face_ids
         COMMAND cadnext_test_procedural_prism_face_ids)
add_test(NAME cadnext_test_face_sketch_reference
         COMMAND cadnext_test_face_sketch_reference)
add_test(NAME cadnext_test_face_selection_resolution
         COMMAND cadnext_test_face_selection_resolution)
add_test(NAME cadnext_test_body_face_selection_state
         COMMAND cadnext_test_body_face_selection_state)
add_test(NAME cadnext_test_face_workplane_serialization
         COMMAND cadnext_test_face_workplane_serialization)
add_test(NAME cadnext_test_workplane_model COMMAND cadnext_test_workplane_model)
add_test(NAME cadnext_test_sketch_reference COMMAND cadnext_test_sketch_reference)
add_test(NAME cadnext_test_sketch_serialization COMMAND cadnext_test_sketch_serialization)
add_test(NAME cadnext_test_sketch_profile_detector COMMAND cadnext_test_sketch_profile_detector)
add_test(NAME cadnext_test_custom_profile_stability
         COMMAND cadnext_test_custom_profile_stability)
add_test(NAME cadnext_test_document COMMAND cadnext_test_document)
add_test(NAME cadnext_test_stub_kernel COMMAND cadnext_test_stub_kernel)
add_test(NAME cadnext_test_bridge_export COMMAND cadnext_test_bridge_export)
add_test(NAME cadnext_test_uavpart_format COMMAND cadnext_test_uavpart_format)
add_test(NAME cadnext_test_primitive_object COMMAND cadnext_test_primitive_object)
add_test(NAME cadnext_test_document_editing COMMAND cadnext_test_document_editing)
add_test(NAME cadnext_test_document_serialization COMMAND cadnext_test_document_serialization)
add_test(NAME cadnext_test_command_stack COMMAND cadnext_test_command_stack)
add_test(NAME cadnext_test_geometry_evaluator_fallback
         COMMAND cadnext_test_geometry_evaluator_fallback)

if(CADNEXT_WITH_OCCT)
    add_executable(cadnext_test_occt_kernel_primitives
        test_occt_kernel_primitives.cpp
    )

    target_link_libraries(cadnext_test_occt_kernel_primitives
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_mesh_extractor
        test_occt_mesh_extractor.cpp
    )

    target_link_libraries(cadnext_test_occt_mesh_extractor
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_geometry_evaluator
        test_geometry_evaluator.cpp
    )

    target_link_libraries(cadnext_test_geometry_evaluator
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_extrude_cut
        test_occt_extrude_cut.cpp
    )

    target_link_libraries(cadnext_test_occt_extrude_cut
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_planar_face_analyzer
        test_occt_planar_face_analyzer.cpp
    )

    target_link_libraries(cadnext_test_occt_planar_face_analyzer
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_mesh_face_ids
        test_occt_mesh_face_ids.cpp
    )

    target_link_libraries(cadnext_test_occt_mesh_face_ids
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_face_pick_resolution
        test_occt_face_pick_resolution.cpp
    )

    target_link_libraries(cadnext_test_occt_face_pick_resolution
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_edge_analyzer
        test_occt_edge_analyzer.cpp
    )

    target_link_libraries(cadnext_test_occt_edge_analyzer
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_chamfer
        test_occt_chamfer.cpp
    )

    target_link_libraries(cadnext_test_occt_chamfer
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_fillet
        test_occt_fillet.cpp
    )

    target_link_libraries(cadnext_test_occt_fillet
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_sketch_on_face_extrude_cut
        test_occt_sketch_on_face_extrude_cut.cpp
    )

    target_link_libraries(cadnext_test_occt_sketch_on_face_extrude_cut
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_chamfer_distance_angle
        test_occt_chamfer_distance_angle.cpp
    )

    target_link_libraries(cadnext_test_occt_chamfer_distance_angle
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_chamfer_after_cut
        test_occt_chamfer_after_cut.cpp
    )

    target_link_libraries(cadnext_test_occt_chamfer_after_cut
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_fillet_after_cut
        test_occt_fillet_after_cut.cpp
    )

    target_link_libraries(cadnext_test_occt_fillet_after_cut
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_edge_reanalysis_after_topology_change
        test_occt_edge_reanalysis_after_topology_change.cpp
    )

    target_link_libraries(cadnext_test_occt_edge_reanalysis_after_topology_change
        PRIVATE
            cadnext_kernel
    )

    add_executable(cadnext_test_occt_mass_properties
        test_occt_mass_properties.cpp
    )

    target_link_libraries(cadnext_test_occt_mass_properties
        PRIVATE
            cadnext_kernel
    )

    add_test(NAME cadnext_test_occt_kernel_primitives
             COMMAND cadnext_test_occt_kernel_primitives)
    add_test(NAME cadnext_test_occt_mesh_extractor
             COMMAND cadnext_test_occt_mesh_extractor)
    add_test(NAME cadnext_test_geometry_evaluator
             COMMAND cadnext_test_geometry_evaluator)
    add_test(NAME cadnext_test_occt_extrude_cut
             COMMAND cadnext_test_occt_extrude_cut)
    add_test(NAME cadnext_test_occt_planar_face_analyzer
             COMMAND cadnext_test_occt_planar_face_analyzer)
    add_test(NAME cadnext_test_occt_mesh_face_ids
             COMMAND cadnext_test_occt_mesh_face_ids)
    add_test(NAME cadnext_test_occt_face_pick_resolution
             COMMAND cadnext_test_occt_face_pick_resolution)
    add_test(NAME cadnext_test_occt_edge_analyzer
             COMMAND cadnext_test_occt_edge_analyzer)
    add_test(NAME cadnext_test_occt_chamfer
             COMMAND cadnext_test_occt_chamfer)
    add_test(NAME cadnext_test_occt_fillet
             COMMAND cadnext_test_occt_fillet)
    add_test(NAME cadnext_test_occt_sketch_on_face_extrude_cut
             COMMAND cadnext_test_occt_sketch_on_face_extrude_cut)
    add_test(NAME cadnext_test_occt_chamfer_distance_angle
             COMMAND cadnext_test_occt_chamfer_distance_angle)
    add_test(NAME cadnext_test_occt_chamfer_after_cut
             COMMAND cadnext_test_occt_chamfer_after_cut)
    add_test(NAME cadnext_test_occt_fillet_after_cut
             COMMAND cadnext_test_occt_fillet_after_cut)
    add_test(NAME cadnext_test_occt_edge_reanalysis_after_topology_change
             COMMAND cadnext_test_occt_edge_reanalysis_after_topology_change)
    add_test(NAME cadnext_test_occt_mass_properties
             COMMAND cadnext_test_occt_mass_properties)
endif()
