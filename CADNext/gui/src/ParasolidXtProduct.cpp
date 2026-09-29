#include "cadnext/gui/ParasolidXtProduct.hpp"
#include "cadnext/gui/ImportProgress.hpp"

#include "cadnext/gui/NativeParasolidXt.hpp"
#include "cadnext/gui/NativeSolidWorksGeometry.hpp"
#include "cadnext/kernel/OcctKernel.hpp"

#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QObject>
#include <QSet>

#include <array>
#include <cmath>
#include <functional>

namespace cadnext::gui {
namespace {

using cadnext::ErrorCode;

struct Matrix {
    std::array<double, 9> r{1, 0, 0, 0, 1, 0, 0, 0, 1}; // row-major: x'_i = r[3i+j] x_j + t_i
    std::array<double, 3> t{0, 0, 0};
};

// The XT Format Reference gives the transform as x' = (rotation_matrix . x + translation_vector) *
// scale with rotation_matrix a C double[3][3], read here row by row.
Matrix matrixOf(const ParasolidXtTransform& transform) {
    Matrix m;
    m.r = transform.rotation;
    m.t = transform.translation;
    return m;
}

double determinant(const Matrix& m) {
    const auto& r = m.r;
    return r[0] * (r[4] * r[8] - r[5] * r[7]) - r[1] * (r[3] * r[8] - r[5] * r[6]) + r[2] * (r[3] * r[7] - r[4] * r[6]);
}

// Rows orthonormal to within the noise a CAD system leaves in a stored rotation (SOLIDWORKS writes
// 1.5e-16 off-diagonal terms into an exact 180° turn). A real shear or a non-unit scale inside the
// matrix is many orders larger.
bool orthonormal(const Matrix& m) {
    constexpr double tolerance = 1e-9;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            const double dot = m.r[3 * i] * m.r[3 * j] + m.r[3 * i + 1] * m.r[3 * j + 1] + m.r[3 * i + 2] * m.r[3 * j + 2];
            if (std::fabs(dot - (i == j ? 1.0 : 0.0)) > tolerance) return false;
        }
    }
    return true;
}

// Unit quaternion (w, x, y, z) of a proper rotation, by the largest-component branch so that no
// division is by a small number.
std::array<double, 4> quaternionOf(const Matrix& m) {
    const auto& r = m.r;
    const double trace = r[0] + r[4] + r[8];
    std::array<double, 4> q{};
    if (trace > 0.0) {
        const double s = std::sqrt(trace + 1.0) * 2.0;
        q = {0.25 * s, (r[7] - r[5]) / s, (r[2] - r[6]) / s, (r[3] - r[1]) / s};
    } else if (r[0] > r[4] && r[0] > r[8]) {
        const double s = std::sqrt(1.0 + r[0] - r[4] - r[8]) * 2.0;
        q = {(r[7] - r[5]) / s, 0.25 * s, (r[1] + r[3]) / s, (r[2] + r[6]) / s};
    } else if (r[4] > r[8]) {
        const double s = std::sqrt(1.0 + r[4] - r[0] - r[8]) * 2.0;
        q = {(r[2] - r[6]) / s, (r[1] + r[3]) / s, 0.25 * s, (r[5] + r[7]) / s};
    } else {
        const double s = std::sqrt(1.0 + r[8] - r[0] - r[4]) * 2.0;
        q = {(r[3] - r[1]) / s, (r[2] + r[6]) / s, (r[5] + r[7]) / s, 0.25 * s};
    }
    const double norm = std::sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    for (double& c : q) c /= norm;
    if (q[0] < 0.0)
        for (double& c : q) c = -c;
    return q;
}

// The kernel's instance matrix: columns are the images of the axes, translation at 12..14.
std::array<double, 16> columnMajor(const Matrix& m) {
    return {m.r[0], m.r[3], m.r[6], 0.0, m.r[1], m.r[4], m.r[7], 0.0,
            m.r[2], m.r[5], m.r[8], 0.0, m.t[0], m.t[1], m.t[2], 1.0};
}

std::string text(const QString& value) { return value.toStdString(); }

} // namespace

cadnext::Result<kernel::ProductStructure> readParasolidXtProduct(kernel::OcctKernel& kernel, const std::string& path,
                                                                 const ImportProgress* progress,
                                                                 ParasolidXtBuildReport* geometry) {
    using R = cadnext::Result<kernel::ProductStructure>;
    if (!kernel.isAvailable()) return R::fail({ErrorCode::KernelUnavailable, "чтение Parasolid XT требует сборки с OCCT"});
    const QString file = QString::fromStdString(path);
    QFile input(file);
    if (!input.open(QIODevice::ReadOnly)) return R::fail({ErrorCode::SerializationFailed, "не удалось открыть " + path});
    ParasolidXtTopology topology;
    QString error;
    if (!readParasolidXtFile(input.readAll(), topology, error)) return R::fail({ErrorCode::SerializationFailed, text(error)});

    // Names and colours are attributes owned by the node they describe.
    QHash<quint32, QString> names;
    QHash<quint32, std::array<double, 3>> colours;
    for (const ParasolidXtAttribute& attribute : topology.attributes) {
        if (attribute.definition == "SDL/TYSA_NAME" && !attribute.strings.empty() && !attribute.strings.front().isEmpty())
            names.insert(attribute.ownerIndex, QString::fromUtf8(attribute.strings.front()));
        else if (attribute.definition == "SDL/TYSA_COLOUR" && attribute.reals.size() == 3)
            colours.insert(attribute.ownerIndex, {attribute.reals[0], attribute.reals[1], attribute.reals[2]});
    }
    const QString stem = QFileInfo(file).completeBaseName();

    kernel::ProductStructure product;
    QHash<quint32, int> partOfBody;
    QHash<quint32, int> bodyNumber;
    for (const ParasolidXtBody& body : topology.bodies) bodyNumber.insert(body.index, int(bodyNumber.size()) + 1);
    const auto bodyName = [&](quint32 body) {
        if (names.contains(body)) return names.value(body);
        return topology.bodies.size() == 1 ? stem : QStringLiteral("%1 — тело %2").arg(stem).arg(bodyNumber.value(body));
    };
    const auto definePart = [&](quint32 body) -> cadnext::Result<int> {
        using P = cadnext::Result<int>;
        if (partOfBody.contains(body)) return P::ok(partOfBody.value(body));
        if (progress) {
            if (progress->cancelled()) return P::fail({ErrorCode::InvalidArgument, text(importCancelledReason())});
            progress->report(int(product.parts.size()), int(topology.bodies.size()),
                             QObject::tr("Тело %1 из %2: %3")
                                 .arg(product.parts.size() + 1)
                                 .arg(topology.bodies.size())
                                 .arg(bodyName(body)));
        }
        const ParasolidXtTopology own = parasolidXtBodyTopology(topology, body);
        kernel::ShapeHandle shape;
        QString failure;
        ParasolidXtBuildReport approximations;
        if (!buildParasolidXtAnalyticSolid(own, kernel, shape, failure, &approximations))
            return P::fail({ErrorCode::ShapeInvalid, "тело «" + text(bodyName(body)) + "»: " + text(failure)});
        if (geometry)
            mergeBuildReport(*geometry, approximations, topology.bodies.size() > 1 ? bodyName(body) : QString());
        else if (const QString note = describeApproximatedFaces(approximations); !note.isEmpty())
            product.warnings.push_back("тело «" + text(bodyName(body)) + "»: " + text(note));
        kernel::ProductPart part;
        part.name = text(bodyName(body));
        part.shape = shape;
        if (colours.contains(body)) part.colour = colours.value(body);
        product.parts.push_back(std::move(part));
        partOfBody.insert(body, int(product.parts.size()) - 1);
        return P::ok(int(product.parts.size()) - 1);
    };

    if (topology.assemblies.empty()) {
        // A part file: its bodies side by side, where Parasolid holds them.
        kernel::ProductAssembly root;
        root.name = text(stem);
        for (const ParasolidXtBody& body : topology.bodies) {
            const auto part = definePart(body.index);
            if (!part.isOk()) return R::fail(part.error());
            kernel::ProductInstance instance;
            instance.name = product.parts[part.value()].name;
            instance.definition = part.value();
            root.instances.push_back(std::move(instance));
        }
        product.assemblies.push_back(std::move(root));
        product.root = 0;
        return R::ok(std::move(product));
    }

    QHash<quint32, const ParasolidXtInstance*> instances;
    QHash<quint32, const ParasolidXtTransform*> transforms;
    QHash<quint32, int> assemblyNumber;
    for (const auto& instance : topology.instances) instances.insert(instance.index, &instance);
    for (const auto& transform : topology.transforms) transforms.insert(transform.index, &transform);
    for (const auto& assembly : topology.assemblies) assemblyNumber.insert(assembly.index, int(assemblyNumber.size()));
    QSet<quint32> instancedParts;
    for (const auto& instance : topology.instances) instancedParts.insert(instance.partIndex);

    product.assemblies.resize(topology.assemblies.size());
    // Assemblies keep their node order as indexes; the instances of each are its chain from
    // sub_instance through next_in_part.
    for (const ParasolidXtAssembly& source : topology.assemblies) {
        kernel::ProductAssembly& assembly = product.assemblies[assemblyNumber.value(source.index)];
        assembly.name = names.contains(source.index) ? text(names.value(source.index)) : std::string();
        QSet<quint32> seen;
        for (quint32 at = source.firstInstance; at != 0;) {
            const ParasolidXtInstance* instance = instances.value(at, nullptr);
            if (!instance || seen.contains(at) || instance->assemblyIndex != source.index)
                return R::fail({ErrorCode::SerializationFailed, "цепочка экземпляров сборки в файле Parasolid повреждена"});
            seen.insert(at);
            at = instance->nextInAssembly;
            const bool ofAssembly = assemblyNumber.contains(instance->partIndex);
            const QString partLabel = ofAssembly ? (names.contains(instance->partIndex) ? names.value(instance->partIndex)
                                                                                       : QStringLiteral("подсборка"))
                                                 : bodyName(instance->partIndex);
            kernel::ProductInstance occurrence;
            occurrence.name = text(names.contains(instance->index) ? names.value(instance->index) : partLabel);
            if (instance->type != 1)
                return R::fail({ErrorCode::UnsupportedOperation,
                                "экземпляр «" + occurrence.name + "» отрицательный (вычитание тела в сборке) — не поддержан"});
            Matrix placement;
            if (instance->transformIndex != 0) {
                const ParasolidXtTransform* transform = transforms.value(instance->transformIndex, nullptr);
                if (!transform) return R::fail({ErrorCode::SerializationFailed, "у экземпляра «" + occurrence.name + "» нет матрицы"});
                if (std::fabs(transform->scale - 1.0) > 1e-12 || !orthonormal(matrixOf(*transform)))
                    return R::fail({ErrorCode::UnsupportedOperation,
                                    "экземпляр «" + occurrence.name + "» вставлен с масштабом или сдвигом осей — это не жёсткое положение"});
                placement = matrixOf(*transform);
            }
            const bool mirrored = determinant(placement) < 0.0;
            if (ofAssembly) {
                if (mirrored)
                    return R::fail({ErrorCode::UnsupportedOperation,
                                    "подсборка «" + occurrence.name + "» вставлена с отражением — это не жёсткое положение"});
                occurrence.isAssembly = true;
                occurrence.definition = assemblyNumber.value(instance->partIndex);
            } else {
                const auto part = definePart(instance->partIndex);
                if (!part.isOk()) return R::fail(part.error());
                occurrence.definition = part.value();
                if (mirrored) {
                    // A mirrored body is a different shape: baked into a part of its own at the
                    // identity, as the STEP import does, and said so.
                    const auto baked = kernel.transformShape(product.parts[part.value()].shape, columnMajor(placement));
                    if (!baked.isOk())
                        return R::fail({baked.error().code, "отражённый экземпляр «" + occurrence.name + "»: " + baked.error().message});
                    kernel::ProductPart copy = product.parts[part.value()];
                    copy.name += " (отражение)";
                    copy.shape = baked.value();
                    product.parts.push_back(std::move(copy));
                    occurrence.definition = int(product.parts.size()) - 1;
                    product.warnings.push_back("экземпляр «" + occurrence.name + "» с отражением записан отдельной деталью");
                    assembly.instances.push_back(std::move(occurrence));
                    continue;
                }
            }
            occurrence.placement.rotation = quaternionOf(placement);
            occurrence.placement.translation = placement.t;
            assembly.instances.push_back(std::move(occurrence));
        }
    }

    // The root: the assembly no instance refers to. Several of them go under one synthesized root,
    // as several top-level products do in the STEP import.
    std::vector<int> roots;
    for (const ParasolidXtAssembly& source : topology.assemblies)
        if (!instancedParts.contains(source.index)) roots.push_back(assemblyNumber.value(source.index));
    if (roots.empty()) return R::fail({ErrorCode::SerializationFailed, "в файле Parasolid нет верхней сборки: сборки ссылаются друг на друга по кругу"});
    for (std::size_t a = 0; a < product.assemblies.size(); ++a)
        if (product.assemblies[a].name.empty())
            product.assemblies[a].name = roots.size() == 1 && int(a) == roots.front() ? text(stem) : text(stem) + " — сборка " + std::to_string(a + 1);
    if (roots.size() == 1) {
        product.root = roots.front();
    } else {
        kernel::ProductAssembly top;
        top.name = text(stem);
        for (int a : roots) {
            kernel::ProductInstance instance;
            instance.name = product.assemblies[a].name;
            instance.isAssembly = true;
            instance.definition = a;
            top.instances.push_back(std::move(instance));
        }
        product.assemblies.push_back(std::move(top));
        product.root = int(product.assemblies.size()) - 1;
    }
    // Bodies nothing instances are not part of the product (a construction body, say): left out,
    // and said so rather than dropped silently.
    for (const ParasolidXtBody& body : topology.bodies)
        if (!instancedParts.contains(body.index))
            product.warnings.push_back("тело «" + text(bodyName(body.index)) + "» не входит ни в один экземпляр сборки и не импортировано");
    if (const std::string problem = kernel::validateProductStructure(product); !problem.empty())
        return R::fail({ErrorCode::SerializationFailed, problem});
    return R::ok(std::move(product));
}

bool parasolidXtProductIsAssembly(const kernel::ProductStructure& product) {
    if (product.assemblies.size() > 1) return true;
    std::size_t occurrences = 0;
    for (const auto& instance : product.assemblies[product.root].instances) {
        ++occurrences;
        const auto& p = instance.placement;
        const bool identity = p.rotation == std::array<double, 4>{1, 0, 0, 0} && p.translation == std::array<double, 3>{0, 0, 0};
        if (!identity) return true;
    }
    return occurrences > product.parts.size();
}

} // namespace cadnext::gui
