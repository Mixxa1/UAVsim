#include "cadnext/gui/BackgroundCadImport.hpp"

#include "cadnext/gui/NativeAcisSat.hpp"
#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeDwgObjects.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/kernel/GeometryEvaluator.hpp"
#include "cadnext/kernel/OcctKernel.hpp"
#include "cadnext/kernel/StepProductStructure.hpp"

#include <QFile>
#include <QFileInfo>
#include <QObject>

#include <functional>
#include <map>

namespace cadnext::gui {

namespace {

struct Found {
    QString name;
    kernel::ShapeHandle shape;
};

// Every occurrence of every part of `product`, placed where the assemblies put it.
QString flatten(kernel::OcctKernel& kernel, const kernel::ProductStructure& product, std::vector<Found>& out) {
    std::function<QString(int, const kernel::ProductPlacement&)> place = [&](int a, const kernel::ProductPlacement& parent) -> QString {
        for (const kernel::ProductInstance& instance : product.assemblies[std::size_t(a)].instances) {
            const kernel::ProductPlacement world = kernel::composePlacements(parent, instance.placement);
            if (instance.isAssembly) {
                if (const QString problem = place(instance.definition, world); !problem.isEmpty()) return problem;
                continue;
            }
            const auto placed = kernel.transformShape(product.parts[std::size_t(instance.definition)].shape,
                                                      kernel::placementMatrix(world));
            if (!placed.isOk()) return QString::fromStdString(placed.error().message);
            out.push_back({QString::fromStdString(instance.name), placed.value()});
        }
        return {};
    };
    return product.assemblies.empty() ? QString() : place(product.root, kernel::ProductPlacement{});
}

} // namespace

bool isBackgroundCadFormat(const QString& suffix) {
    static const QStringList formats{"sldprt", "sldasm", "x_t", "x_b", "xmt_txt", "xmt_bin",
                                     "step", "stp", "iges", "igs", "fcstd", "sat", "dwg", "m3d", "a3d"};
    return formats.contains(suffix);
}

BodyImportResult importBodiesFromFile(const QString& path, const ImportProgress* progress,
                                      const QString& configuration) {
    BodyImportResult result;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) {
        result.error = QObject::tr("Для импорта требуется сборка с OCCT.");
        return result;
    }
    const QString suffix = QFileInfo(path).suffix().toLower();
    const QString stem = QFileInfo(path).completeBaseName();
    const auto reading = [&](const QString& what) {
        if (progress) progress->report(0, 0, what);
    };
    std::vector<Found> found;
    QString error;
    if (suffix == QLatin1String("sldprt")) {
        reading(QObject::tr("Деталь: %1").arg(stem));
        kernel::ShapeHandle shape;
        if (!readSolidWorksAnalyticPart(path, exchange, shape, error, &result.geometry, configuration)) {
            const QString analyticError = error;
            if (!readSolidWorksPlanarPart(path, exchange, shape, error, configuration)) {
                result.error = analyticError;
                return result;
            }
        }
        found.push_back({configuration.isEmpty() ? stem : stem + QStringLiteral(" (") + configuration + QLatin1Char(')'), shape});
        result.notes << QObject::tr("История операций SOLIDWORKS не переносится: тело — точный снимок");
    } else if (suffix == QLatin1String("sldasm")) {
        kernel::ProductStructure product;
        if (readSolidWorksAssemblyProduct(path, exchange, product, error, &result.geometry, progress)) {
            if (const QString problem = flatten(exchange, product, found); !problem.isEmpty()) {
                result.error = problem;
                return result;
            }
            for (const std::string& warning : product.warnings) result.notes << QString::fromStdString(warning);
        } else {
            if (progress && progress->cancelled()) {
                result.error = importCancelledReason();
                return result;
            }
            const QString analyticError = error;
            std::vector<SolidWorksImportedBody> components;
            if (!readSolidWorksPlanarAssembly(path, exchange, components, error)) {
                result.error = analyticError;
                return result;
            }
            for (const auto& component : components) found.push_back({component.name, component.shape});
        }
    } else if (suffix == QLatin1String("x_t") || suffix == QLatin1String("x_b") || suffix == QLatin1String("xmt_txt") ||
               suffix == QLatin1String("xmt_bin")) {
        const auto product = readParasolidXtProduct(exchange, path.toStdString(), progress, &result.geometry);
        if (!product.isOk()) {
            result.error = QString::fromStdString(product.error().message);
            return result;
        }
        if (const QString problem = flatten(exchange, product.value(), found); !problem.isEmpty()) {
            result.error = problem;
            return result;
        }
        for (const std::string& warning : product.value().warnings) result.notes << QString::fromStdString(warning);
    } else if (suffix == QLatin1String("step") || suffix == QLatin1String("stp")) {
        reading(QObject::tr("Чтение STEP…"));
        const auto parts = exchange.importStepAssembly(path.toStdString());
        if (!parts.isOk()) {
            result.error = QString::fromStdString(parts.error().message);
            return result;
        }
        for (const auto& part : parts.value()) found.push_back({QString::fromStdString(part.name), part.shape});
    } else if (suffix == QLatin1String("iges") || suffix == QLatin1String("igs")) {
        reading(QObject::tr("Чтение IGES…"));
        const auto shape = exchange.importExchangeFile(path.toStdString());
        if (!shape.isOk()) {
            result.error = QString::fromStdString(shape.error().message);
            return result;
        }
        found.push_back({stem, shape.value()});
    } else if (suffix == QLatin1String("sat")) {
        reading(QObject::tr("Чтение ACIS SAT…"));
        AcisSatResult sat;
        if (!readAcisSatFile(path, exchange, sat, error, &result.geometry)) {
            result.error = error;
            return result;
        }
        for (const AcisSatSolid& solid : sat.solids) found.push_back({solid.name, solid.shape});
        result.notes << sat.notes;
    } else if (suffix == QLatin1String("m3d")) {
        // KOMPAS-3D part: the solids as the C3D kernel's own serialisation in the file holds them.
        reading(QObject::tr("Чтение КОМПАС-3D…"));
        KompasC3dResult kompas;
        if (!readKompasC3dSolids(path, exchange, kompas, error, &result.geometry)) {
            result.error = error;
            return result;
        }
        for (const KompasSolid& solid : kompas.solids) found.push_back({solid.name, solid.shape});
        result.notes << kompas.notes;
    } else if (suffix == QLatin1String("a3d")) {
        // KOMPAS-3D assembly: each component's part, read from its own .m3d next to the assembly (once, however
        // often it is used), placed by the component's frame. Missing parts are named.
        reading(QObject::tr("Чтение сборки КОМПАС-3D…"));
        kernel::ProductStructure product;
        QStringList notes;
        if (!readKompasAssemblyProduct(path, exchange, product, error, notes, &result.geometry, progress)) {
            result.error = error;
            return result;
        }
        if (const QString problem = flatten(exchange, product, found); !problem.isEmpty()) {
            result.error = problem;
            return result;
        }
        result.notes << notes;
    } else if (suffix == QLatin1String("dwg") || suffix == QLatin1String("dxf")) {
        // DWG R13–R2000 or DXF: the ACIS solids its model shows, through blocks and external references, each
        // built on its own and placed; one that does not build is named in the notes, the rest come in.
        reading(suffix == QLatin1String("dxf") ? QObject::tr("Чтение DXF…") : QObject::tr("Чтение DWG…"));
        DwgModel dwg;
        if (!readDwgModel(path, dwg, error)) {
            result.error = error;
            return result;
        }
        QStringList failed;
        for (std::size_t i = 0; i < dwg.bodies.size(); ++i) {
            const DwgModelBody& body = dwg.bodies[i];
            if (progress) {
                if (progress->cancelled()) {
                    result.error = importCancelledReason();
                    return result;
                }
                progress->report(int(i), int(dwg.bodies.size()), QObject::tr("Тело %1 из %2: %3").arg(i + 1).arg(dwg.bodies.size()).arg(body.name));
            }
            AcisSatResult sat;
            QString why;
            if (!readAcisSat(body.acis, exchange, sat, why, &result.geometry, body.name, body.millimetresPerUnit)) {
                failed << QObject::tr("%1: %2").arg(body.name, why);
                continue;
            }
            for (const QString& note : sat.notes)
                if (!result.notes.contains(note)) result.notes << note;
            for (const AcisSatSolid& solid : sat.solids) {
                const auto placed = exchange.transformShape(solid.shape, body.placement);
                if (!placed.isOk()) {
                    failed << QObject::tr("%1: %2").arg(body.name, QString::fromStdString(placed.error().message));
                    continue;
                }
                found.push_back({sat.solids.size() == 1 ? body.name : solid.name, placed.value()});
            }
        }
        if (dwg.bodies.empty()) {
            QString why = QObject::tr("В модели %1 %2 нет твердотельных тел ACIS (3DSOLID, BODY, детали Mechanical Desktop).")
                              .arg(suffix.toUpper(), dwg.version);
            if (!dwg.notes.isEmpty()) why += '\n' + dwg.notes.join('\n');
            result.error = why;
            return result;
        }
        if (found.empty()) {
            result.error = QObject::tr("Ни одно из %1 тел %2 не построено:\n%3").arg(dwg.bodies.size()).arg(suffix.toUpper(), failed.join('\n'));
            return result;
        }
        result.notes << dwg.notes;
        if (!failed.isEmpty())
            result.notes << QObject::tr("Тел не построено: %1 из %2").arg(failed.size()).arg(dwg.bodies.size()) << failed;
    } else if (suffix == QLatin1String("fcstd")) {
        reading(QObject::tr("Чтение FreeCAD…"));
        std::vector<FreeCadShape> shapes;
        if (!readFreeCadShapes(path, shapes, error)) {
            result.error = error;
            return result;
        }
        for (const FreeCadShape& part : shapes) {
            const auto* begin = reinterpret_cast<const std::uint8_t*>(part.brep.constData());
            const auto shape = exchange.importFreeCadBRep(std::vector<std::uint8_t>(begin, begin + part.brep.size()), part.binary);
            if (!shape.isOk()) {
                result.error = QString::fromStdString(shape.error().message);
                return result;
            }
            found.push_back({part.name, shape.value()});
        }
    } else {
        result.error = QObject::tr("Формат %1 здесь не читается.").arg(suffix);
        return result;
    }

    // Meshes, BRep and the faces and edges picking needs — the heavy part of showing a body.
    kernel::GeometryEvaluator evaluator(exchange);
    kernel::FaceAnalyzer faces(exchange);
    kernel::EdgeAnalyzer edges(exchange);
    for (std::size_t i = 0; i < found.size(); ++i) {
        if (progress) {
            if (progress->cancelled()) {
                result.error = importCancelledReason();
                result.bodies.clear();
                return result;
            }
            progress->report(int(i), int(found.size()),
                             QObject::tr("Сетка тела %1 из %2: %3").arg(i + 1).arg(found.size()).arg(found[i].name));
        }
        const auto evaluated = evaluator.evaluateShape(found[i].shape);
        if (!evaluated.isOk()) {
            result.error = QString::fromStdString(evaluated.error().message);
            return result;
        }
        if (!evaluated.value().isValid || evaluated.value().previewMesh.isEmpty()) {
            result.error = QObject::tr("В файле нет отображаемого твердого тела: %1").arg(found[i].name);
            return result;
        }
        const auto bytes = exchange.exportBRepGeometry(found[i].shape);
        if (!bytes.isOk()) {
            result.error = QString::fromStdString(bytes.error().message);
            return result;
        }
        ImportedBody body;
        body.name = found[i].name;
        body.brep = bytes.value();
        body.mesh = evaluated.value().previewMesh;
        body.faces = faces.planarFacesForBody({}, found[i].shape);
        body.edges = edges.edgesForBody({}, found[i].shape);
        result.bodies.push_back(std::move(body));
    }
    return result;
}

bool cadFileLooksLikeAssembly(const QString& path) {
    const QString suffix = QFileInfo(path).suffix().toLower();
    if (suffix == QLatin1String("a3d")) return true; // a KOMPAS-3D assembly, whatever it holds
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return false;
    if (suffix == QLatin1String("x_t") || suffix == QLatin1String("x_b") || suffix == QLatin1String("xmt_txt") ||
        suffix == QLatin1String("xmt_bin")) {
        ParasolidXtTopology topology;
        QString error;
        return readParasolidXtFile(file.readAll(), topology, error) && !topology.assemblies.empty();
    }
    if (suffix == QLatin1String("step") || suffix == QLatin1String("stp")) {
        // Read in blocks, the entity name split across two of them kept whole.
        const QByteArray entity("NEXT_ASSEMBLY_USAGE_OCCURRENCE");
        QByteArray carry;
        while (!file.atEnd()) {
            const QByteArray block = carry + file.read(1 << 20);
            if (block.contains(entity)) return true;
            carry = block.right(entity.size() - 1);
        }
    }
    return false;
}

} // namespace cadnext::gui
