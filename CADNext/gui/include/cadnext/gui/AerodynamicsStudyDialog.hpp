#pragma once
#include <QDialog>
#include <cadnext/bridge/ConstructionExport.hpp>
namespace cadnext::gui {
// Opens a snapshot of the current document; later CAD edits cannot change a running job.
void showAerodynamicsStudy(bridge::ConstructionDescriptor construction, QWidget* parent);
// Native result-only viewer; optional snapshot prefix produces two animation frames.
void showAerodynamicsResult(const QString& path,const QString& snapshotPrefix={},QWidget* parent=nullptr);
}
