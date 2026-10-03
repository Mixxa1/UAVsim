#include "cadnext/gui/AssemblyStepExchange.hpp"
#include "cadnext/gui/NativeKompasC3d.hpp"
#include "cadnext/gui/NativeKompasAssembly.hpp"
#include "cadnext/gui/NativeKompasWriter.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"

#include "cadnext/Document.hpp"
#include "cadnext/DocumentSerializer.hpp"
#include "cadnext/assembly/AssemblyModel.hpp"
#include "cadnext/assembly/AssemblyRecomputeEngine.hpp"
#include "cadnext/assembly/AssemblySerializer.hpp"
#include "cadnext/gui/AssemblyPartLoader.hpp"
#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/gui/ParasolidXtWriter.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QDir>
#include <QFileInfo>
#include <QObject>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <functional>
#include <map>
#include <set>

namespace cadnext::gui {

namespace fs = std::filesystem;

namespace {

kernel::ProductPlacement toProduct(const assembly::Placement& placement) {
    const assembly::Quaternion q = placement.rotation.normalized();
    kernel::ProductPlacement product;
    product.rotation = {q.w, q.x, q.y, q.z};
    product.translation = {placement.translation.x, placement.translation.y, placement.translation.z};
    return product;
}

assembly::Placement fromProduct(const kernel::ProductPlacement& product) {
    assembly::Placement placement;
    placement.rotation.w = product.rotation[0];
    placement.rotation.x = product.rotation[1];
    placement.rotation.y = product.rotation[2];
    placement.rotation.z = product.rotation[3];
    placement.translation = {product.translation[0], product.translation[1], product.translation[2]};
    return placement;
}

// A file name a user would recognise: the part's own name with the characters no file system takes
// replaced. Cyrillic stays as it is.
std::string safeFileName(const std::string& name, const std::string& fallback) {
    std::string out;
    for (const char c : name) out += (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' || c == '"' || c == '<' || c == '>' || c == '|') ? '_' : c;
    while (!out.empty() && (out.back() == ' ' || out.back() == '.')) out.pop_back();
    return out.empty() ? fallback : out;
}

// A path in `folder` not taken yet in this import: "Вал.cadnext", then "Вал (2).cadnext".
fs::path uniquePath(const fs::path& folder, const std::string& stem, const std::string& extension, std::set<std::string>& taken) {
    fs::path candidate = folder / (stem + extension);
    for (int n = 2; taken.count(candidate.string()) || fs::exists(candidate); ++n) {
        candidate = folder / (stem + " (" + std::to_string(n) + ")" + extension);
    }
    taken.insert(candidate.string());
    return candidate;
}

std::string fileStem(const std::string& path) { return fs::path(path).stem().string(); }

int leafOccurrences(const kernel::ProductStructure& structure) {
    std::function<int(int)> leaves = [&](int a) {
        int n = 0;
        for (const auto& instance : structure.assemblies[a].instances) n += instance.isAssembly ? leaves(instance.definition) : 1;
        return n;
    };
    return leaves(structure.root);
}

// The product structure of a .cadasm, its shapes registered in `exchange`: what both exports write.
cadnext::Result<bool> collectAssemblyProduct(const std::string& cadasmPath, kernel::OcctKernel& exchange,
                                             kernel::ProductStructure& structure, AssemblyExchangeReport& report) {
    using R = cadnext::Result<bool>;
    AssemblyPartLoader loader;
    std::map<std::string, int> partByKey, assemblyByPath;
    std::set<std::string> onPath;
    std::string error;

    // A part file (+ body) becomes one STEP part, however many components link to it.
    const auto definePart = [&](const assembly::AssemblyComponent& component) -> int {
        const std::string key = component.source.filePath + '\n' + component.source.bodyId;
        if (const auto found = partByKey.find(key); found != partByKey.end()) return found->second;
        const AssemblyPartGeometry& geometry = loader.geometryForSource(component.source);
        if (!geometry.valid || geometry.exactShape.isNull()) {
            error = "деталь «" + component.name + "» (" + component.source.filePath + "): "
                    + (geometry.error.isEmpty() ? std::string("нет точной геометрии") : geometry.error.toStdString());
            return -1;
        }
        const auto bytes = loader.kernel().exportBRepGeometry(geometry.exactShape);
        if (!bytes.isOk()) {
            error = "деталь «" + component.name + "»: " + bytes.error().message;
            return -1;
        }
        const auto shape = exchange.importBRep(bytes.value());
        if (!shape.isOk()) {
            error = "деталь «" + component.name + "»: " + shape.error().message;
            return -1;
        }
        kernel::ProductPart part;
        part.name = geometry.displayName.empty() ? fileStem(component.source.filePath) : geometry.displayName;
        part.shape = shape.value();
        structure.parts.push_back(std::move(part));
        partByKey[key] = static_cast<int>(structure.parts.size()) - 1;
        return partByKey[key];
    };

    // A .cadasm becomes one STEP assembly, however many times it is inserted; its joints are solved
    // first so the components leave where the Assembly workbench shows them.
    std::function<int(const std::string&)> defineAssembly = [&](const std::string& path) -> int {
        const std::string absolute = fs::absolute(path).lexically_normal().string();
        if (const auto found = assemblyByPath.find(absolute); found != assemblyByPath.end()) return found->second;
        if (onPath.count(absolute)) {
            error = "сборка " + absolute + " содержит сама себя";
            return -1;
        }
        const auto loaded = assembly::AssemblySerializer::loadFromFile(absolute);
        if (!loaded.isOk()) {
            error = "сборка " + absolute + ": " + loaded.error().message;
            return -1;
        }
        onPath.insert(absolute);
        assembly::AssemblyDocument document = loaded.value();
        assembly::AssemblyRecomputeEngine engine;
        engine.recompute(document, [&](const assembly::AssemblyComponent& component) -> const assembly::PartTopology* {
            if (component.source.kind == assembly::PartSourceKind::Assembly) {
                const AssemblyPartGeometry& merged = loader.geometryForSource(component.source);
                return merged.valid ? &merged.topology : nullptr;
            }
            const AssemblyPartGeometry& part = loader.geometryForSource(component.source);
            return part.valid ? &part.topology : nullptr;
        });

        kernel::ProductAssembly product;
        product.name = document.name().empty() ? fileStem(absolute) : document.name();
        for (const assembly::AssemblyComponent& component : document.components()) {
            if (component.isSuppressed) continue;
            kernel::ProductInstance instance;
            instance.name = component.name;
            instance.placement = toProduct(component.placement);
            if (component.source.kind == assembly::PartSourceKind::Assembly) {
                instance.isAssembly = true;
                instance.definition = defineAssembly(component.source.filePath);
            } else {
                instance.definition = definePart(component);
            }
            if (instance.definition < 0) return -1;
            product.instances.push_back(std::move(instance));
        }
        onPath.erase(absolute);
        if (product.instances.empty()) report.warnings.push_back("сборка «" + product.name + "» пуста: в ней нет неподавленных компонентов");
        structure.assemblies.push_back(std::move(product));
        assemblyByPath[absolute] = static_cast<int>(structure.assemblies.size()) - 1;
        return assemblyByPath[absolute];
    };

    structure.root = defineAssembly(cadasmPath);
    if (structure.root < 0) return R::fail({ErrorCode::NotFound, error});
    report.parts = static_cast<int>(structure.parts.size());
    report.assemblies = static_cast<int>(structure.assemblies.size());
    report.occurrences = leafOccurrences(structure);
    return R::ok(true);
}

} // namespace

cadnext::Result<AssemblyExchangeReport> exportAssemblyToStep(const std::string& cadasmPath, const std::string& stepPath,
                                                             kernel::StepSchema schema) {
    using R = cadnext::Result<AssemblyExchangeReport>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "обмен STEP требует сборки с OCCT"});
    kernel::ProductStructure structure;
    AssemblyExchangeReport report;
    if (const auto collected = collectAssemblyProduct(cadasmPath, exchange, structure, report); !collected.isOk())
        return R::fail(collected.error());
    const auto written = kernel::writeStepProductStructure(exchange, structure, stepPath, schema);
    if (!written.isOk()) return R::fail(written.error());
    return R::ok(std::move(report));
}

cadnext::Result<AssemblyExchangeReport> exportAssemblyToParasolid(const std::string& cadasmPath, const std::string& xtPath,
                                                                  ParasolidXtEncoding encoding) {
    using R = cadnext::Result<AssemblyExchangeReport>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "запись Parasolid XT требует сборки с OCCT"});
    kernel::ProductStructure structure;
    AssemblyExchangeReport report;
    if (const auto collected = collectAssemblyProduct(cadasmPath, exchange, structure, report); !collected.isOk())
        return R::fail(collected.error());
    const auto written = writeParasolidXtProduct(exchange, structure, xtPath, encoding);
    if (!written.isOk()) return R::fail(written.error());
    report.warnings.insert(report.warnings.end(), written.value().warnings.begin(), written.value().warnings.end());
    return R::ok(std::move(report));
}

cadnext::Result<AssemblyExchangeReport> exportAssemblyToKompas(const std::string& cadasmPath, const std::string& a3dPath) {
    using R = cadnext::Result<AssemblyExchangeReport>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "запись КОМПАС-3D требует сборки с OCCT"});
    kernel::ProductStructure structure;
    AssemblyExchangeReport report;
    if (const auto collected = collectAssemblyProduct(cadasmPath, exchange, structure, report); !collected.isOk())
        return R::fail(collected.error());
    if (structure.assemblies.empty()) return R::fail({ErrorCode::InvalidArgument, "в сборке нет ни одного вхождения"});
    // Leaf occurrences from the root, placements composed (the parent's rotation, then its translation).
    struct Leaf {
        int part;
        kernel::ProductPlacement placement;
    };
    std::vector<Leaf> leaves;
    bool nested = false;
    const auto compose = [](const kernel::ProductPlacement& a, const kernel::ProductPlacement& b) {
        const auto& p = a.rotation;
        const auto& q = b.rotation;
        kernel::ProductPlacement c;
        c.rotation = {p[0] * q[0] - p[1] * q[1] - p[2] * q[2] - p[3] * q[3], p[0] * q[1] + p[1] * q[0] + p[2] * q[3] - p[3] * q[2],
                      p[0] * q[2] - p[1] * q[3] + p[2] * q[0] + p[3] * q[1], p[0] * q[3] + p[1] * q[2] - p[2] * q[1] + p[3] * q[0]};
        // b's translation turned by a's rotation (v' = v + 2w(r × v) + 2 r × (r × v)), then a's added.
        const double w = p[0], rx = p[1], ry = p[2], rz = p[3];
        const auto& v = b.translation;
        const double cx = ry * v[2] - rz * v[1], cy = rz * v[0] - rx * v[2], cz = rx * v[1] - ry * v[0];
        const double dx = ry * cz - rz * cy, dy = rz * cx - rx * cz, dz = rx * cy - ry * cx;
        c.translation = {a.translation[0] + v[0] + 2 * (w * cx + dx), a.translation[1] + v[1] + 2 * (w * cy + dy),
                         a.translation[2] + v[2] + 2 * (w * cz + dz)};
        return c;
    };
    const std::function<void(int, const kernel::ProductPlacement&, int)> walk = [&](int assembly, const kernel::ProductPlacement& at, int depth) {
        if (depth > 32 || assembly < 0 || std::size_t(assembly) >= structure.assemblies.size()) return;
        for (const auto& instance : structure.assemblies[std::size_t(assembly)].instances) {
            const auto placement = compose(at, instance.placement);
            if (instance.isAssembly) {
                nested = true;
                walk(instance.definition, placement, depth + 1);
            } else if (instance.definition >= 0 && std::size_t(instance.definition) < structure.parts.size()) {
                leaves.push_back({instance.definition, placement});
            }
        }
    };
    walk(structure.root, kernel::ProductPlacement{}, 0);
    if (leaves.empty()) return R::fail({ErrorCode::InvalidArgument, "в сборке нет деталей"});
    if (leaves.size() > kKompasAssemblyLinkKeys)
        return R::fail({ErrorCode::UnsupportedOperation,
                        QObject::tr("Сборка КОМПАС-3D пока записывается до %1 вхождений, а здесь их %2: ключи связей MetaInfo для "
                                    "большего числа компонентов неизвестны.").arg(kKompasAssemblyLinkKeys).arg(leaves.size()).toStdString()});
    // One part file per part placed, its name the part's (made unique, and safe as a file name).
    std::vector<KompasAssemblyPart> parts;
    std::map<int, std::size_t> partIndex;
    std::set<QString> names;
    std::vector<KompasAssemblyComponent> components;
    for (const auto& leaf : leaves) {
        auto found = partIndex.find(leaf.part);
        if (found == partIndex.end()) {
            const auto& source = structure.parts[std::size_t(leaf.part)];
            QString base = QString::fromStdString(source.name).trimmed();
            for (QChar& ch : base)
                if (QStringLiteral("/\\:*?\"<>|").contains(ch) || ch.unicode() < 32) ch = QLatin1Char('_');
            if (base.isEmpty()) base = QStringLiteral("Part");
            QString file = base + QStringLiteral(".m3d");
            for (int k = 2; names.count(file.toLower()); ++k) file = QStringLiteral("%1 %2.m3d").arg(base).arg(k);
            names.insert(file.toLower());
            KompasAssemblyPart part;
            part.fileName = file;
            part.bodies = {{source.shape, 0, base}};
            part.options.title = base;
            if (source.colour) {
                // Linear RGB to the 8-bit sRGB KOMPAS keeps.
                quint32 rgb = 0;
                for (const double linear : *source.colour) {
                    const double v = std::clamp(linear, 0.0, 1.0);
                    const double s = v <= 0.0031308 ? 12.92 * v : 1.055 * std::pow(v, 1 / 2.4) - 0.055;
                    rgb = (rgb << 8) | quint32(std::lround(s * 255));
                }
                part.options.color = rgb;
            }
            found = partIndex.emplace(leaf.part, parts.size()).first;
            parts.push_back(std::move(part));
        }
        components.push_back({found->second, leaf.placement});
    }
    KompasNativeWriteOptions options;
    options.title = QString::fromStdString(structure.assemblies[std::size_t(structure.root)].name);
    if (options.title.isEmpty()) options.title = QFileInfo(QString::fromStdString(a3dPath)).completeBaseName();
    QString error;
    if (!writeKompasNativeAssembly(exchange, parts, components, QString::fromStdString(a3dPath), error, options))
        return R::fail({ErrorCode::SerializationFailed, error.toStdString()});
    report.parts = int(parts.size());
    report.assemblies = 1;
    report.occurrences = int(components.size());
    if (nested) report.warnings.push_back("Подсборки развёрнуты в одну сборку КОМПАС-3D: их вхождения записаны с итоговыми положениями.");
    report.warnings.push_back("Детали записаны файлами .m3d рядом со сборкой.");
    return R::ok(std::move(report));
}

cadnext::Result<std::string> importStepAsAssembly(const std::string& stepPath, const std::string& folder,
                                                  AssemblyExchangeReport& report, const ImportProgress* progress) {
    using R = cadnext::Result<std::string>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "обмен STEP требует сборки с OCCT"});
    if (progress) progress->report(0, 0, QObject::tr("Чтение STEP…"));
    const auto read = kernel::readStepProductStructure(exchange, stepPath);
    if (!read.isOk()) return R::fail(read.error());
    return writeProductAsAssembly(exchange, read.value(), folder, "STEP", report, progress);
}

cadnext::Result<std::string> importParasolidXtAsAssembly(const std::string& xtPath, const std::string& folder,
                                                         AssemblyExchangeReport& report, const ImportProgress* progress) {
    using R = cadnext::Result<std::string>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "чтение Parasolid XT требует сборки с OCCT"});
    report.geometry = {};
    const auto read = readParasolidXtProduct(exchange, xtPath, progress, &report.geometry);
    if (!read.isOk()) return R::fail(read.error());
    return writeProductAsAssembly(exchange, read.value(), folder, "Parasolid", report, progress);
}

cadnext::Result<std::string> importSolidWorksAsAssembly(const std::string& sldasmPath, const std::string& folder,
                                                        AssemblyExchangeReport& report, const ImportProgress* progress,
                                                        const std::string& configuration) {
    using R = cadnext::Result<std::string>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "чтение SOLIDWORKS требует сборки с OCCT"});
    kernel::ProductStructure product;
    ParasolidXtBuildReport notes;
    QString error;
    const QString path = QString::fromStdString(sldasmPath);
    if (QFileInfo(path).suffix().compare(QLatin1String("sldprt"), Qt::CaseInsensitive) == 0) {
        // A single part: one part, placed once where it is.
        if (progress) progress->report(0, 1, QObject::tr("Деталь: %1").arg(QFileInfo(path).completeBaseName()));
        kernel::ProductPart part;
        part.name = QFileInfo(path).completeBaseName().toStdString();
        if (!readSolidWorksAnalyticPart(path, exchange, part.shape, error, &notes, QString::fromStdString(configuration)))
            return R::fail({ErrorCode::SerializationFailed, error.toStdString()});
        product.parts.push_back(part);
        kernel::ProductAssembly root;
        root.name = part.name;
        kernel::ProductInstance instance;
        instance.name = part.name;
        instance.definition = 0;
        root.instances.push_back(instance);
        product.assemblies.push_back(root);
    } else if (!readSolidWorksAssemblyProduct(path, exchange, product, error, &notes, progress)) {
        return R::fail({ErrorCode::SerializationFailed, error.toStdString()});
    }
    report.geometry = notes;
    return writeProductAsAssembly(exchange, product, folder, "SOLIDWORKS", report, progress);
}

cadnext::Result<std::string> importKompasAsAssembly(const std::string& path, const std::string& folder,
                                                    AssemblyExchangeReport& report, const ImportProgress* progress) {
    using R = cadnext::Result<std::string>;
    kernel::OcctKernel exchange;
    if (!exchange.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "чтение КОМПАС-3D требует сборки с OCCT"});
    kernel::ProductStructure product;
    ParasolidXtBuildReport notes;
    QString error;
    QStringList warnings;
    const QString source = QString::fromStdString(path);
    if (QFileInfo(source).suffix().compare(QLatin1String("m3d"), Qt::CaseInsensitive) == 0) {
        // A single part: its bodies, each placed once where it is.
        if (progress) progress->report(0, 1, QObject::tr("Деталь: %1").arg(QFileInfo(source).completeBaseName()));
        KompasC3dResult solids;
        if (!readKompasC3dSolids(source, exchange, solids, error, &notes)) return R::fail({ErrorCode::SerializationFailed, error.toStdString()});
        kernel::ProductAssembly root;
        root.name = QFileInfo(source).completeBaseName().toStdString();
        for (const KompasSolid& solid : solids.solids) {
            kernel::ProductPart part;
            part.name = solid.name.toStdString();
            part.shape = solid.shape;
            kernel::ProductInstance instance;
            instance.name = part.name;
            instance.definition = int(product.parts.size());
            product.parts.push_back(part);
            root.instances.push_back(instance);
        }
        product.assemblies.push_back(root);
        warnings = solids.notes;
    } else if (!readKompasAssemblyProduct(source, exchange, product, error, warnings, &notes, progress)) {
        return R::fail({ErrorCode::SerializationFailed, error.toStdString()});
    }
    report.geometry = notes;
    for (const QString& warning : warnings) report.warnings.push_back(warning.toStdString());
    return writeProductAsAssembly(exchange, product, folder, "КОМПАС-3D", report, progress);
}

cadnext::Result<std::string> writeProductAsAssembly(kernel::OcctKernel& exchange, const kernel::ProductStructure& structure,
                                                    const std::string& folder, const std::string& format,
                                                    AssemblyExchangeReport& report, const ImportProgress* progress) {
    using R = cadnext::Result<std::string>;
    report.warnings = structure.warnings;

    std::error_code created;
    fs::create_directories(folder, created);
    if (created) return R::fail({ErrorCode::SerializationFailed, "не удалось создать папку " + folder + ": " + created.message()});
    const fs::path base = fs::absolute(folder).lexically_normal();
    std::set<std::string> taken;

    // Decide every file name first: an assembly can name a subassembly written after it.
    std::vector<fs::path> partPaths, assemblyPaths;
    for (std::size_t p = 0; p < structure.parts.size(); ++p) {
        partPaths.push_back(uniquePath(base, safeFileName(structure.parts[p].name, "Деталь " + std::to_string(p + 1)), ".cadnext", taken));
    }
    for (std::size_t a = 0; a < structure.assemblies.size(); ++a) {
        assemblyPaths.push_back(uniquePath(base, safeFileName(structure.assemblies[a].name, "Сборка " + std::to_string(a + 1)), ".cadasm", taken));
    }

    bool colourDropped = false;
    const std::string bodyId = "body-1";
    for (std::size_t p = 0; p < structure.parts.size(); ++p) {
        const kernel::ProductPart& part = structure.parts[p];
        if (progress) {
            if (progress->cancelled()) return R::fail({ErrorCode::InvalidArgument, importCancelledReason().toStdString()});
            progress->report(int(p), int(structure.parts.size()),
                             QObject::tr("Запись детали %1 из %2").arg(p + 1).arg(structure.parts.size()));
        }
        const auto bytes = exchange.exportBRepGeometry(part.shape);
        if (!bytes.isOk()) return R::fail({bytes.error().code, "деталь «" + part.name + "»: " + bytes.error().message});
        Document document;
        document.setName(part.name);
        Object body;
        body.id = bodyId;
        body.name = part.name;
        body.type = ObjectType::Body;
        body.primitive.kind = PrimitiveKind::None;
        body.importedBRep = bytes.value();
        document.addObject(std::move(body));
        const auto saved = DocumentSerializer::saveToFile(document, partPaths[p].string());
        if (!saved.isOk()) return R::fail({saved.error().code, "деталь «" + part.name + "»: " + saved.error().message});
        colourDropped = colourDropped || part.colour.has_value();
    }
    if (colourDropped) {
        report.warnings.push_back("цвета деталей из файла " + format + " в документы CADNext не перенесены: у тела в .cadnext пока нет поля цвета");
    }

    // Children before parents, so every link to a subassembly can carry the content hash of a file
    // that already exists — the same change detection parts get.
    std::vector<int> order;
    std::vector<bool> placed(structure.assemblies.size(), false);
    std::function<void(int)> postOrder = [&](int a) {
        if (placed[a]) return;
        placed[a] = true;
        for (const auto& instance : structure.assemblies[a].instances)
            if (instance.isAssembly) postOrder(instance.definition);
        order.push_back(a);
    };
    postOrder(structure.root);
    for (int a = 0; a < static_cast<int>(structure.assemblies.size()); ++a) postOrder(a);

    for (const int a : order) {
        const kernel::ProductAssembly& product = structure.assemblies[a];
        assembly::AssemblyDocument document;
        document.setName(product.name);
        int n = 0;
        for (const kernel::ProductInstance& instance : product.instances) {
            assembly::AssemblyComponent component;
            component.id = "component-" + std::to_string(++n);
            component.name = instance.name.empty() ? product.name + " " + std::to_string(n) : instance.name;
            component.placement = fromProduct(instance.placement);
            if (instance.isAssembly) {
                component.source.kind = assembly::PartSourceKind::Assembly;
                component.source.filePath = assemblyPaths[instance.definition].string();
                component.source.contentHash = assembly::AssemblySerializer::contentHashForFile(component.source.filePath);
            } else {
                component.source.kind = assembly::PartSourceKind::CadnextDocument;
                component.source.filePath = partPaths[instance.definition].string();
                component.source.bodyId = bodyId;
                component.source.contentHash = assembly::AssemblySerializer::contentHashForFile(component.source.filePath);
            }
            // Nothing is constrained yet: the first component anchors the assembly, the rest stay
            // where the file placed them.
            component.isGrounded = n == 1;
            document.addComponent(std::move(component));
        }
        const auto saved = assembly::AssemblySerializer::saveToFile(document, assemblyPaths[a].string());
        if (!saved.isOk()) return R::fail({saved.error().code, "сборка «" + product.name + "»: " + saved.error().message});
    }

    report.parts = static_cast<int>(structure.parts.size());
    report.assemblies = static_cast<int>(structure.assemblies.size());
    std::function<int(int)> leaves = [&](int a) {
        int count = 0;
        for (const auto& instance : structure.assemblies[a].instances) count += instance.isAssembly ? leaves(instance.definition) : 1;
        return count;
    };
    report.occurrences = leaves(structure.root);
    return R::ok(assemblyPaths[structure.root].string());
}

} // namespace cadnext::gui
