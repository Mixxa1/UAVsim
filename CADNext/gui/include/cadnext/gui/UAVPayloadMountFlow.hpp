#pragma once

namespace cadnext::gui {

// Tracks the active step in the «тестировать на БЛА» flow.
// The window manager (UAVPartPreviewPanel → UAVSelectionDialog →
// UAVMountEditorDialog) advances and retreats these steps using the
// Variant-B hide/show pattern — each step maps to exactly one window,
// hidden behind the next one rather than destroyed.
enum class CADPayloadMountFlowStep {
    partPreview,   // .uavpart window is visible; flow not yet started
    uavSelection,  // UAVSelectionDialog is open; .uavpart window is hidden
    mountEditor,   // UAVMountEditorDialog is open; UAVSelectionDialog is hidden
    completed,     // flow finished normally (Подтвердить крепления)
    cancelled,     // flow terminated by user (Закрыть / OS close)
};

} // namespace cadnext::gui
