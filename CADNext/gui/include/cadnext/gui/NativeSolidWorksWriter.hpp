#pragma once

#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/gui/NativeSolidWorksFeatureBodies.hpp"

#include <QByteArray>
#include <QString>

#include <vector>
#include <optional>

namespace cadnext::gui {

// The caller assigns these ids from the document's operation/body namespace.
// Use the same pair in the operation output, stored body and current partition.
struct SolidWorksImportedBodyIdentity {
    qint32 featureId = 0;
    qint32 bodyAtomId = 0;
};

struct SolidWorksWriteConfiguration {
    quint32 id = 0;
    QString name;
    kernel::ShapeHandle shape;
    std::optional<SolidWorksImportedBodyIdentity> importedBody;
};

struct SolidWorksWriteSection {
    QByteArray name;
    QByteArray data; // uncompressed native section payload
};

// Native configuration data: complete CMgrHdr2 (MFC archive with manager footer)
// and current WORLD-root
// Parasolid partitions. No template document, SDK or original model is used.
// This is a document-writer component, NOT a complete SLDPRT: the model's
// configuration object graph (Config-N, CMgr, ResolvedFeatures), document
// metadata (Definition) and outer document directory still have to be
// authored before these sections can be published as a native document.
// Header2/ModelHeader has a separate codec in NativeSolidWorksDocument.hpp;
// this geometry-section API does not author or include those model headers.
// On failure `sections` is empty. Coordinates in partitions remain metres.
bool encodeSolidWorksConfigurationSections(
    kernel::OcctKernel& kernel,
    const std::vector<SolidWorksWriteConfiguration>& configurations,
    std::vector<SolidWorksWriteSection>& sections, QString& error);

// Builds the named imported feature's LocalBodies section using our own XT
// geometry writer. The caller must still author the feature object and its
// configuration/manager links before publishing a complete native document.
// When identities are supplied, they must name one operation and distinct
// positive body atoms. They are written as native integer BODY attributes.
// On failure `section` is empty. Each supplied shape is stored independently.
bool encodeSolidWorksImportedFeatureBodySection(
    kernel::OcctKernel& kernel, quint32 configurationId, const QString& featureName,
    const std::vector<kernel::ShapeHandle>& shapes,
    SolidWorksWriteSection& section, QString& error,
    SolidWorksFeatureBodyLayout layout = SolidWorksFeatureBodyLayout::GroupedBodies,
    const std::vector<SolidWorksImportedBodyIdentity>& identities = {});

// Packs the authored CMgrHdr2 and Config-N partitions into an independent
// legacy CFB container. The physical `.SLDPRT` container is complete for these
// streams; the SOLIDWORKS application graph (Config-N/CMgr/Definition and
// feature history) is intentionally validated separately before this endpoint
// is promoted to a full native-document writer.
bool writeSolidWorksConfigurationContainer(
    kernel::OcctKernel& kernel,
    const std::vector<SolidWorksWriteConfiguration>& configurations,
    const QString& path, QString& error);

} // namespace cadnext::gui
