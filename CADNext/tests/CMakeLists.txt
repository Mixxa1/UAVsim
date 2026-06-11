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

add_executable(cadnext_test_sketch_snap
    test_sketch_snap.cpp
)

target_link_libraries(cadnext_test_sketch_snap
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

add_test(NAME cadnext_test_sketch_model COMMAND cadnext_test_sketch_model)
add_test(NAME cadnext_test_sketch_snap COMMAND cadnext_test_sketch_snap)
add_test(NAME cadnext_test_sketch_plane_mapping COMMAND cadnext_test_sketch_plane_mapping)
add_test(NAME cadnext_test_sketch_reference_projection
         COMMAND cadnext_test_sketch_reference_projection)
add_test(NAME cadnext_test_workplane_visibility_policy
         COMMAND cadnext_test_workplane_visibility_policy)
add_test(NAME cadnext_test_sketch2d_view_state COMMAND cadnext_test_sketch2d_view_state)
add_test(NAME cadnext_test_sketch_reference_mapping
         COMMAND cadnext_test_sketch_reference_mapping)
add_test(NAME cadnext_test_extrude_parameters COMMAND cadnext_test_extrude_parameters)
add_test(NAME cadnext_test_extrude_direction COMMAND cadnext_test_extrude_direction)
add_test(NAME cadnext_test_extrude_serialization
         COMMAND cadnext_test_extrude_serialization)
add_test(NAME cadnext_test_workplane_model COMMAND cadnext_test_workplane_model)
add_test(NAME cadnext_test_sketch_reference COMMAND cadnext_test_sketch_reference)
add_test(NAME cadnext_test_sketch_serialization COMMAND cadnext_test_sketch_serialization)
add_test(NAME cadnext_test_sketch_profile_detector COMMAND cadnext_test_sketch_profile_detector)
add_test(NAME cadnext_test_document COMMAND cadnext_test_document)
add_test(NAME cadnext_test_stub_kernel COMMAND cadnext_test_stub_kernel)
add_test(NAME cadnext_test_bridge_export COMMAND cadnext_test_bridge_export)
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

    add_test(NAME cadnext_test_occt_kernel_primitives
             COMMAND cadnext_test_occt_kernel_primitives)
    add_test(NAME cadnext_test_occt_mesh_extractor
             COMMAND cadnext_test_occt_mesh_extractor)
    add_test(NAME cadnext_test_geometry_evaluator
             COMMAND cadnext_test_geometry_evaluator)
endif()
