#include "cadnext/gui/NativeSolidWorksGeometry.hpp"

#include "cadnext/gui/NativeCadImport.hpp"
#include "cadnext/gui/NativeParasolidXt.hpp"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QSet>
#include <QObject>
#include <QStringList>

#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <utility>

namespace cadnext::gui {
namespace {

// XT keeps a periodic B-spline unwrapped: n poles, n + degree + 1 flat knots whose spacing repeats,
// the domain [t_degree, t_n] one period, and the last `overlap` poles repeating the first — as many
// as degree + 1 − the multiplicity of the seam's knot (NIST ctc_02: 42 poles, degree 3, knots all
// double, 2 repeated). OCCT's periodic form is one period: the knots in [t_degree, t_n] at their
// multiplicities, n − overlap poles. Returns false when the data is not of that form; the unwrapped,
// non-periodic reading is the same geometry over its domain and is what the caller keeps then.
bool periodicPeriod(const std::vector<double>& knots, const std::vector<int>& multiplicities, int degree,
                    int poles, std::vector<double>& periodKnots, std::vector<int>& periodMultiplicities,
                    int& periodPoles) {
    std::vector<double> flat;
    for (std::size_t i = 0; i < knots.size(); ++i)
        for (int m = 0; m < multiplicities[i]; ++m) flat.push_back(knots[i]);
    if (degree < 1 || poles <= 2 * degree || int(flat.size()) != poles + degree + 1) return false;
    const double low = flat[degree], high = flat[poles], period = high - low;
    if (!(period > 0)) return false;
    periodKnots.clear();
    periodMultiplicities.clear();
    for (std::size_t i = 0; i < knots.size(); ++i) {
        if (knots[i] < low || knots[i] > high) continue;
        periodKnots.push_back(knots[i]);
        periodMultiplicities.push_back(multiplicities[i]);
    }
    if (periodKnots.size() < 2 || periodKnots.front() != low || periodKnots.back() != high ||
        periodMultiplicities.front() != periodMultiplicities.back())
        return false;
    periodPoles = 0;
    for (std::size_t i = 0; i + 1 < periodMultiplicities.size(); ++i) periodPoles += periodMultiplicities[i];
    const int overlap = poles - periodPoles;
    if (overlap < 1 || overlap > degree) return false;
    // The knot spacing repeats with the period.
    for (int j = 0; j + periodPoles < int(flat.size()); ++j)
        if (std::fabs(flat[j + periodPoles] - flat[j] - period) > 1e-12 * std::max(1.0, period)) return false;
    return true;
}

bool samePole(const cadnext::Vector3& a, const cadnext::Vector3& b, double wa, double wb) {
    const double size = std::max({1.0, std::fabs(a.x), std::fabs(a.y), std::fabs(a.z)});
    return std::fabs(a.x - b.x) <= 1e-12 * size && std::fabs(a.y - b.y) <= 1e-12 * size &&
           std::fabs(a.z - b.z) <= 1e-12 * size && std::fabs(wa - wb) <= 1e-12 * std::max(1.0, wa);
}

void wrapPeriodic(kernel::BSplineCurveDefinition& d) {
    if (!d.periodic) return;
    d.periodic = false;
    std::vector<double> knots;
    std::vector<int> multiplicities;
    const int n = int(d.poles.size());
    int kept = 0;
    if (!periodicPeriod(d.knots, d.multiplicities, d.degree, n, knots, multiplicities, kept)) return;
    for (int i = 0; i < n - kept; ++i)
        if (!samePole(d.poles[kept + i], d.poles[i], d.weights[kept + i], d.weights[i])) return;
    d.poles.resize(kept);
    d.weights.resize(kept);
    d.knots = std::move(knots);
    d.multiplicities = std::move(multiplicities);
    d.periodic = true;
}

void wrapPeriodic(kernel::BSplineSurfaceDefinition& d) {
    // The grid is u-major (index u * nv + v), as the builder reads it first.
    for (int direction = 0; direction < 2; ++direction) {
        bool& periodic = direction == 0 ? d.uPeriodic : d.vPeriodic;
        if (!periodic) continue;
        periodic = false;
        const int n = direction == 0 ? d.uPoleCount : d.vPoleCount;
        const int p = direction == 0 ? d.uDegree : d.vDegree;
        std::vector<double> knots;
        std::vector<int> multiplicities;
        int kept = 0;
        if (!periodicPeriod(direction == 0 ? d.uKnots : d.vKnots,
                            direction == 0 ? d.uMultiplicities : d.vMultiplicities, p, n, knots, multiplicities, kept))
            continue;
        const auto at = [&](int u, int v) { return u * d.vPoleCount + v; };
        bool repeats = true;
        for (int i = 0; i < n - kept && repeats; ++i) {
            for (int other = 0; other < (direction == 0 ? d.vPoleCount : d.uPoleCount) && repeats; ++other) {
                const int a = direction == 0 ? at(kept + i, other) : at(other, kept + i);
                const int b = direction == 0 ? at(i, other) : at(other, i);
                repeats = samePole(d.poles[a], d.poles[b], d.weights[a], d.weights[b]);
            }
        }
        if (!repeats) continue;
        std::vector<cadnext::Vector3> poles;
        std::vector<double> weights;
        for (int u = 0; u < d.uPoleCount; ++u)
            for (int v = 0; v < d.vPoleCount; ++v)
                if ((direction == 0 ? u : v) < kept) {
                    poles.push_back(d.poles[at(u, v)]);
                    weights.push_back(d.weights[at(u, v)]);
                }
        d.poles = std::move(poles);
        d.weights = std::move(weights);
        (direction == 0 ? d.uPoleCount : d.vPoleCount) = kept;
        (direction == 0 ? d.uKnots : d.vKnots) = std::move(knots);
        (direction == 0 ? d.uMultiplicities : d.vMultiplicities) = std::move(multiplicities);
        periodic = true;
    }
}

const SolidWorksBodyStream* selectPartition(const std::vector<SolidWorksBodyStream>& streams,
                                            const QString& configuration, QString& error) {
    const SolidWorksBodyStream* selected = nullptr;
    int matchesCount = 0;
    QStringList available;
    const bool storageId = configuration.startsWith(QLatin1String("Config-"));
    const QString wanted = storageId ? configuration.mid(7) : configuration;
    for (const auto& stream : streams) {
        if (stream.kind != QLatin1String("partition")) continue;
        available << (stream.configurationName.isEmpty() ? stream.configuration
                        : stream.configurationName + QStringLiteral(" [") + stream.configuration + QLatin1Char(']'));
        const bool matches = configuration.isEmpty() ||
            (storageId ? stream.configuration == wanted :
                         stream.configurationName == wanted || stream.configuration == wanted);
        if (!matches) continue;
        ++matchesCount;
        selected = &stream;
    }
    if (matchesCount > 1) {
        error = QObject::tr("В детали несколько конфигураций; выберите одну: %1.").arg(available.join(QStringLiteral(", ")));
        return nullptr;
    }
    if (!selected)
        error = QObject::tr("Конфигурация «%1» не содержит сохранённой точной геометрии. Доступны: %2.")
                    .arg(configuration, available.join(QStringLiteral(", ")));
    return selected;
}

QString configurationKey(const QString& path, const QString& configuration) {
    return path + QChar(u'\0') + configuration;
}

bool readPlanarPatches(const QString& path,
                       std::vector<kernel::PlanarFacePatch>& patches,
                       QString& error, const QString& configuration = {}) {
    error.clear();
    std::vector<SolidWorksBodyStream> streams;
    if (!readSolidWorksPartBodyStreams(path, streams, error)) return false;
    const SolidWorksBodyStream* partition = selectPartition(streams, configuration, error);
    ParasolidXtTopology topology;
    if (!partition ||
        !readParasolidXtTopology(partition->parasolid, topology, error)) {
        if (error.isEmpty())
            error = QObject::tr("В детали отсутствует читаемый раздел Parasolid XT.");
        return false;
    }
    std::vector<ParasolidXtFaceWire> wires;
    if (!parasolidXtFaceWires(topology, wires, error)) return false;
    const auto planarFaces = parasolidXtPlanarFaces(topology);
    if (topology.bodyCount != 1 || planarFaces.size() != topology.faces.size()) {
        error = QObject::tr("Деталь содержит несколько тел, криволинейные "
                            "или многоконтурные грани. Точный импорт сейчас "
                            "поддерживает одно замкнутое полигональное тело.");
        return false;
    }
    patches.clear();
    patches.reserve(planarFaces.size());
    for (const auto& face : planarFaces) {
        kernel::PlanarFacePatch patch;
        patch.planeOrigin = {face.planeOrigin[0], face.planeOrigin[1],
                             face.planeOrigin[2]};
        patch.planeNormal = {face.planeNormal[0], face.planeNormal[1],
                             face.planeNormal[2]};
        for (const auto& point : face.outline)
            patch.outline.push_back({point[0], point[1], point[2]});
        patches.push_back(std::move(patch));
    }
    return true;
}

cadnext::Vector3 cross(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return {a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x};
}

double dot(const cadnext::Vector3& a, const cadnext::Vector3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

bool transformPatches(std::vector<kernel::PlanarFacePatch>& patches,
                      const std::array<double, 16>& matrix) {
    constexpr double tolerance = 1e-9;
    if (std::fabs(matrix[3]) > tolerance || std::fabs(matrix[7]) > tolerance ||
        std::fabs(matrix[11]) > tolerance ||
        std::fabs(matrix[15] - 1.0) > tolerance) return false;
    // swTransform stores a 4x4 affine matrix with translation at 12..14.
    const cadnext::Vector3 x{matrix[0], matrix[1], matrix[2]};
    const cadnext::Vector3 y{matrix[4], matrix[5], matrix[6]};
    const cadnext::Vector3 z{matrix[8], matrix[9], matrix[10]};
    const cadnext::Vector3 translation{matrix[12], matrix[13], matrix[14]};
    const cadnext::Vector3 nx = cross(y, z);
    const cadnext::Vector3 ny = cross(z, x);
    const cadnext::Vector3 nz = cross(x, y);
    if (!std::isfinite(dot(x, nx)) || std::fabs(dot(x, nx)) <= 1e-12)
        return false;
    const auto point = [&](const cadnext::Vector3& p) -> cadnext::Vector3 {
        return {x.x * p.x + y.x * p.y + z.x * p.z + translation.x,
                x.y * p.x + y.y * p.y + z.y * p.z + translation.y,
                x.z * p.x + y.z * p.y + z.z * p.z + translation.z};
    };
    const auto normal = [&](const cadnext::Vector3& n) -> cadnext::Vector3 {
        // Cofactor matrix preserves the orientation under any invertible
        // affine transform, including a reflection or nonuniform scale.
        return {nx.x * n.x + ny.x * n.y + nz.x * n.z,
                nx.y * n.x + ny.y * n.y + nz.y * n.z,
                nx.z * n.x + ny.z * n.y + nz.z * n.z};
    };
    for (auto& patch : patches) {
        patch.planeOrigin = point(patch.planeOrigin);
        patch.planeNormal = normal(patch.planeNormal);
        for (auto& vertex : patch.outline) vertex = point(vertex);
        if (!std::isfinite(patch.planeOrigin.x) ||
            !std::isfinite(patch.planeOrigin.y) ||
            !std::isfinite(patch.planeOrigin.z) ||
            !std::isfinite(patch.planeNormal.x) ||
            !std::isfinite(patch.planeNormal.y) ||
            !std::isfinite(patch.planeNormal.z)) return false;
    }
    return true;
}

} // namespace

bool readSolidWorksPlanarPart(const QString& path, kernel::OcctKernel& kernel,
                             kernel::ShapeHandle& shape, QString& error, const QString& configuration) {
    shape = {};
    std::vector<kernel::PlanarFacePatch> patches;
    if (!readPlanarPatches(path, patches, error, configuration)) return false;
    const auto solid = kernel.makePlanarSolid(patches);
    if (!solid.isOk()) {
        error = QObject::tr("Грани детали не образуют одно замкнутое тело: %1")
                    .arg(QString::fromStdString(solid.error().message));
        return false;
    }
    shape = solid.value();
    error.clear();
    return true;
}

QString describeApproximatedFaces(const ParasolidXtBuildReport& report) {
    // Tolerant edges are the source's own inexactness, told as such: the faces there meet within the
    // file's tolerance, however exactly each is built.
    const QString tolerant = report.tolerantEdges == 0 ? QString()
        : QObject::tr("Рёбра с допуском: %1. Грани по обе стороны такого ребра сходятся в самом файле "
                      "лишь с точностью его допуска (каждая по своей кривой); наибольший допуск ребра или "
                      "вершины — %2 м. Тело сшито в пределах удвоенного допуска, сами грани построены точно.")
              .arg(report.tolerantEdges)
              .arg(report.largestEdgeTolerance, 0, 'g', 3);
    // Faces held one per turn: the same surface and boundary, more faces than the file has.
    QString turns;
    if (!report.split.empty()) {
        QStringList where;
        int faces = 0;
        for (const auto& face : report.split) {
            faces += face.faces;
            where << (face.body.isEmpty() ? QObject::tr("узел FACE %1 → %2").arg(face.faceIndex).arg(face.faces)
                                          : QObject::tr("%1: узел FACE %2 → %3").arg(face.body).arg(face.faceIndex).arg(face.faces));
        }
        turns = QObject::tr("Грани, обвивающие цилиндр или конус больше одного оборота (корень резьбы): %1 — "
                            "всего %2 граней вместо %3. OCCT держит такую грань только по одной на виток; "
                            "поверхность и граница у них те же, что в файле, соседние витки сходятся по шву.")
                    .arg(where.join(QStringLiteral(", ")))
                    .arg(faces)
                    .arg(report.split.size());
    }
    const auto joined = [](QStringList parts) {
        parts.removeAll(QString());
        return parts.join(QLatin1Char(' '));
    };
    if (report.approximated.empty()) return joined({tolerant, turns});
    double deviation = 0.0, gap = 0.0;
    // Face nodes by body, in the order met.
    std::vector<std::pair<QString, QStringList>> bodies;
    for (const auto& face : report.approximated) {
        deviation = std::max(deviation, face.deviation);
        gap = std::max(gap, face.contactGap);
        if (bodies.empty() || bodies.back().first != face.body) bodies.push_back({face.body, {}});
        bodies.back().second << QString::number(face.faceIndex);
    }
    QStringList where;
    for (const auto& [body, faces] : bodies) {
        const QString list = faces.size() <= 12
            ? faces.join(QStringLiteral(", "))
            : QObject::tr("%1 и ещё %2").arg(faces.mid(0, 12).join(QStringLiteral(", "))).arg(faces.size() - 12);
        where << (body.isEmpty() ? QObject::tr("узлы FACE %1").arg(list)
                                 : QObject::tr("%1: узлы FACE %2").arg(body, list));
    }
    const QString blends =
        QObject::tr("Скругления восстановлены приближённо: %1 граней (%2). Такая грань — след шара "
                    "постоянного радиуса, катящегося по спине между двумя опорами; замкнутой формы у неё нет, "
                    "поэтому она построена рациональным B-сплайном. Отклонение от этого определения — "
                    "не больше %3 м (допуск импорта 1e-6 м); сам файл выполняет определение с точностью %4 м.")
            .arg(report.approximated.size())
            .arg(where.join(QStringLiteral("; ")))
            .arg(deviation, 0, 'g', 2)
            .arg(gap, 0, 'g', 2);
    return joined({blends, tolerant, turns});
}

QStringList summarizeBuildReport(const ParasolidXtBuildReport& report) {
    QStringList lines;
    if (!report.approximated.empty()) {
        double deviation = 0.0;
        for (const auto& face : report.approximated) deviation = std::max(deviation, face.deviation);
        lines << QObject::tr("Скругления приближены B-сплайном: %1 гр., отклонение ≤ %2 м")
                     .arg(report.approximated.size())
                     .arg(deviation, 0, 'g', 2);
    }
    if (report.tolerantEdges > 0)
        lines << QObject::tr("Рёбра с допуском из файла: %1, до %2 м")
                     .arg(report.tolerantEdges)
                     .arg(report.largestEdgeTolerance, 0, 'g', 2);
    if (!report.split.empty()) {
        int faces = 0;
        for (const auto& face : report.split) faces += face.faces;
        lines << QObject::tr("Корни резьбы по виткам: %1 гр. → %2").arg(report.split.size()).arg(faces);
    }
    return lines;
}

void mergeBuildReport(ParasolidXtBuildReport& whole, const ParasolidXtBuildReport& part, const QString& body) {
    for (auto face : part.approximated) {
        if (!body.isEmpty()) face.body = body;
        whole.approximated.push_back(face);
    }
    whole.tolerantEdges += part.tolerantEdges;
    whole.largestEdgeTolerance = std::max(whole.largestEdgeTolerance, part.largestEdgeTolerance);
    for (auto face : part.split) {
        if (!body.isEmpty()) face.body = body;
        whole.split.push_back(face);
    }
}

bool readSolidWorksAnalyticPart(const QString& path, kernel::OcctKernel& kernel,
                               kernel::ShapeHandle& shape, QString& error,
                               ParasolidXtBuildReport* report, const QString& configuration) {
    shape = {};
    if (report) *report = {};
    std::vector<SolidWorksBodyStream> streams;
    if (!readSolidWorksPartBodyStreams(path, streams, error)) return false;
    const SolidWorksBodyStream* partition = selectPartition(streams, configuration, error);
    ParasolidXtTopology topology;
    if (!partition || !readParasolidXtTopology(partition->parasolid, topology, error))
        return false;
    return buildParasolidXtAnalyticSolid(topology, kernel, shape, error, report);
}

bool readParasolidXtAnalyticFile(const QString& path, kernel::OcctKernel& kernel,
                                 kernel::ShapeHandle& shape, QString& error,
                                 ParasolidXtBuildReport* report) {
    shape = {};
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        error = QObject::tr("Не удалось открыть файл %1.").arg(path);
        return false;
    }
    ParasolidXtTopology topology;
    if (!readParasolidXtFile(file.readAll(), topology, error)) return false;
    return buildParasolidXtAnalyticSolid(topology, kernel, shape, error, report);
}

bool buildParasolidXtAnalyticSolid(const ParasolidXtTopology& topology,
                                   kernel::OcctKernel& kernel,
                                   kernel::ShapeHandle& shape, QString& error,
                                   ParasolidXtBuildReport* report) {
    shape = {};
    if (report) *report = {};
    if (topology.bodyCount != 1) {
        error = QObject::tr("Точный аналитический импорт ожидает одно тело.");
        return false;
    }
    std::vector<ParasolidXtFaceWire> wires;
    if (!parasolidXtFaceWires(topology, wires, error)) return false;
    QHash<quint32, const ParasolidXtAnalyticGeometry*> geometry;
    for (const auto& item : topology.analyticGeometry)
        geometry.insert(item.index, &item);
    QHash<quint32, std::vector<const ParasolidXtFaceWire*>> faceWires;
    for (const auto& wire : wires) faceWires[wire.faceIndex].push_back(&wire);
    std::vector<kernel::AnalyticFacePatch> patches;
    patches.reserve(topology.faces.size());
    const auto convert = [](const std::array<double, 3>& p) -> cadnext::Vector3 {
        return {p[0], p[1], p[2]};
    };
    const auto splineCurve = [&](const ParasolidXtAnalyticGeometry& curve,
                                 kernel::BSplineCurveDefinition& result) {
        const auto* definition = geometry.value(curve.links.value("nurbs"), nullptr);
        if (!definition || definition->type != 136) return false;
        const auto* vertices = geometry.value(definition->links.value("bspline_vertices"), nullptr);
        const auto* multiplicities = geometry.value(definition->links.value("knot_mult"), nullptr);
        const auto* knots = geometry.value(definition->links.value("knots"), nullptr);
        if (!vertices || vertices->type != 45 || !multiplicities ||
            multiplicities->type != 127 || !knots || knots->type != 128)
            return false;
        const auto poleValues = vertices->realArrays.constFind("vertices");
        const auto knotValues = knots->realArrays.constFind("knots");
        const auto multValues = multiplicities->integerArrays.constFind("mult");
        if (poleValues == vertices->realArrays.cend() ||
            knotValues == knots->realArrays.cend() ||
            multValues == multiplicities->integerArrays.cend()) return false;
        const quint32 count = definition->integers.value("n_vertices");
        const quint32 dimension = definition->integers.value("vertex_dim");
        const quint32 knotCount = definition->integers.value("n_knots");
        const quint32 degree = definition->integers.value("degree");
        const bool rational = definition->bytes.value("rational") != 0;
        if (count < 2 || count > 100'000 || degree < 1 || degree > 25 ||
            count <= degree || dimension != (rational ? 4u : 3u) ||
            poleValues.value().size() < count * dimension ||
            multValues.value().size() < knotCount ||
            knotValues.value().size() < knotCount ||
            knotCount < 2)
            return false;
        const auto& raw = poleValues.value();
        result = {};
        result.degree = int(degree);
        result.periodic = definition->bytes.value("periodic") != 0;
        result.poles.reserve(count);
        result.weights.reserve(count);
        for (quint32 i = 0; i < count; ++i) {
            const double weight = rational ? raw[i * dimension + 3] : 1.0;
            if (!std::isfinite(weight) || weight <= 0.0) return false;
            result.poles.push_back({raw[i * dimension] / weight,
                                    raw[i * dimension + 1] / weight,
                                    raw[i * dimension + 2] / weight});
            result.weights.push_back(weight);
        }
        const auto& rawKnots = knotValues.value();
        const auto& rawMultiplicities = multValues.value();
        for (quint32 i = 0; i < knotCount; ++i) {
            if (!std::isfinite(rawKnots[i]) ||
                (i > 0 && rawKnots[i] <= rawKnots[i - 1]) ||
                rawMultiplicities[i] < 1 || rawMultiplicities[i] > degree + 1)
                return false;
            result.knots.push_back(rawKnots[i]);
            result.multiplicities.push_back(int(rawMultiplicities[i]));
        }
        wrapPeriodic(result);
        return true;
    };
    const auto splineSurface = [&](const ParasolidXtAnalyticGeometry& surface,
                                   kernel::BSplineSurfaceDefinition& result) {
        const auto* definition = geometry.value(surface.links.value("nurbs"), nullptr);
        if (!definition || definition->type != 126) return false;
        const auto* vertices = geometry.value(definition->links.value("bspline_vertices"), nullptr);
        const auto* uMult = geometry.value(definition->links.value("u_knot_mult"), nullptr);
        const auto* vMult = geometry.value(definition->links.value("v_knot_mult"), nullptr);
        const auto* uKnots = geometry.value(definition->links.value("u_knots"), nullptr);
        const auto* vKnots = geometry.value(definition->links.value("v_knots"), nullptr);
        if (!vertices || vertices->type != 45 || !uMult || uMult->type != 127 ||
            !vMult || vMult->type != 127 || !uKnots || uKnots->type != 128 ||
            !vKnots || vKnots->type != 128)
            return false;
        const auto poleValues = vertices->realArrays.constFind("vertices");
        const auto uMultValues = uMult->integerArrays.constFind("mult");
        const auto vMultValues = vMult->integerArrays.constFind("mult");
        const auto uKnotValues = uKnots->realArrays.constFind("knots");
        const auto vKnotValues = vKnots->realArrays.constFind("knots");
        if (poleValues == vertices->realArrays.cend() ||
            uMultValues == uMult->integerArrays.cend() ||
            vMultValues == vMult->integerArrays.cend() ||
            uKnotValues == uKnots->realArrays.cend() ||
            vKnotValues == vKnots->realArrays.cend()) return false;
        const quint32 nu = definition->integers.value("n_u_vertices");
        const quint32 nv = definition->integers.value("n_v_vertices");
        const quint32 du = definition->integers.value("u_degree");
        const quint32 dv = definition->integers.value("v_degree");
        const quint32 nku = definition->integers.value("n_u_knots");
        const quint32 nkv = definition->integers.value("n_v_knots");
        const bool rational = definition->bytes.value("rational") != 0;
        const quint32 dimension = definition->integers.value("vertex_dim");
        if (nu < 2 || nv < 2 || nu > 100'000 / nv || du < 1 || dv < 1 ||
            du > 25 || dv > 25 || nu <= du || nv <= dv ||
            dimension != (rational ? 4u : 3u) || nku < 2 || nkv < 2 ||
            poleValues.value().size() < nu * nv * dimension ||
            uMultValues.value().size() < nku ||
            vMultValues.value().size() < nkv ||
            uKnotValues.value().size() < nku ||
            vKnotValues.value().size() < nkv)
            return false;
        result = {};
        result.uDegree = int(du);
        result.vDegree = int(dv);
        result.uPoleCount = int(nu);
        result.vPoleCount = int(nv);
        result.uPeriodic = definition->bytes.value("u_periodic") != 0;
        result.vPeriodic = definition->bytes.value("v_periodic") != 0;
        const auto& raw = poleValues.value();
        result.poles.reserve(nu * nv);
        result.weights.reserve(nu * nv);
        for (quint32 i = 0; i < nu * nv; ++i) {
            const double weight = rational ? raw[i * dimension + 3] : 1.0;
            if (!std::isfinite(weight) || weight <= 0.0) return false;
            result.poles.push_back({raw[i * dimension] / weight,
                                    raw[i * dimension + 1] / weight,
                                    raw[i * dimension + 2] / weight});
            result.weights.push_back(weight);
        }
        const auto copyKnots = [](const ParasolidXtAnalyticGeometry& knotNode,
                                  const ParasolidXtAnalyticGeometry& multNode,
                                  int degree, qsizetype count,
                                  std::vector<double>& knotValues,
                                  std::vector<int>& multValues) {
            const auto& sourceKnots = knotNode.realArrays.constFind("knots").value();
            const auto& sourceMults = multNode.integerArrays.constFind("mult").value();
            for (qsizetype i = 0; i < count; ++i) {
                if (!std::isfinite(sourceKnots[i]) ||
                    (i && sourceKnots[i] <= sourceKnots[i - 1]) ||
                    sourceMults[i] < 1 || sourceMults[i] > quint32(degree + 1))
                    return false;
                knotValues.push_back(sourceKnots[i]);
                multValues.push_back(int(sourceMults[i]));
            }
            return true;
        };
        if (!copyKnots(*uKnots, *uMult, int(du), nku, result.uKnots, result.uMultiplicities) ||
            !copyKnots(*vKnots, *vMult, int(dv), nkv, result.vKnots, result.vMultiplicities))
            return false;
        wrapPeriodic(result);
        return true;
    };
    // A section curve of a swept surface: the curve itself, whatever its sense (XT: R(u, v) =
    // C(u) + v·D with C in its natural parametrisation).
    const auto sectionOf = [&](const ParasolidXtAnalyticGeometry* curve, kernel::AnalyticEdgeSegment& section) {
        if (curve && curve->type == 133) curve = geometry.value(curve->links.value("basis_curve"), nullptr);
        if (!curve) return false;
        section = {};
        if (curve->type == 30) {
            section.kind = kernel::AnalyticEdgeKind::Line;
            section.center = convert(curve->vectors.value("pvec"));
            section.normal = convert(curve->vectors.value("direction"));
            return true;
        }
        if (curve->type == 31 || curve->type == 32) {
            section.kind = curve->type == 31 ? kernel::AnalyticEdgeKind::Circle : kernel::AnalyticEdgeKind::Ellipse;
            section.center = convert(curve->vectors.value("centre"));
            section.normal = convert(curve->vectors.value("normal"));
            section.xAxis = convert(curve->vectors.value("x_axis"));
            section.radius = curve->reals.value("radius");
            section.majorRadius = curve->reals.value("major_radius");
            section.minorRadius = curve->reals.value("minor_radius");
            return true;
        }
        if (curve->type == 134) {
            section.kind = kernel::AnalyticEdgeKind::BSpline;
            return splineCurve(*curve, section.bspline);
        }
        return false;
    };
    // The 2D B-curve of an SP-curve, in its surface's (u, v): vertex_dim 2, or 3 when rational;
    // its poles given with z = 0.
    const auto planeCurve = [&](const ParasolidXtAnalyticGeometry& curve, kernel::BSplineCurveDefinition& result) {
        const auto* definition = geometry.value(curve.links.value("nurbs"), nullptr);
        if (!definition || definition->type != 136) return false;
        const auto* vertices = geometry.value(definition->links.value("bspline_vertices"), nullptr);
        const auto* multiplicities = geometry.value(definition->links.value("knot_mult"), nullptr);
        const auto* knots = geometry.value(definition->links.value("knots"), nullptr);
        if (!vertices || !multiplicities || !knots) return false;
        const auto poles = vertices->realArrays.value("vertices");
        const auto knotValues = knots->realArrays.value("knots");
        const auto multValues = multiplicities->integerArrays.value("mult");
        const quint32 count = definition->integers.value("n_vertices");
        const quint32 dimension = definition->integers.value("vertex_dim");
        const quint32 knotCount = definition->integers.value("n_knots");
        const quint32 degree = definition->integers.value("degree");
        const bool rational = definition->bytes.value("rational") != 0;
        if (count < 2 || degree < 1 || count <= degree || dimension != (rational ? 3u : 2u) ||
            poles.size() < std::size_t(count) * dimension || knotValues.size() < knotCount || multValues.size() < knotCount)
            return false;
        result = {};
        result.degree = int(degree);
        result.periodic = definition->bytes.value("periodic") != 0;
        for (quint32 i = 0; i < count; ++i) {
            const double w = rational ? poles[i * dimension + 2] : 1.0;
            if (!(w > 0.0)) return false;
            result.poles.push_back({poles[i * dimension] / w, poles[i * dimension + 1] / w, 0.0});
            result.weights.push_back(w);
        }
        for (quint32 i = 0; i < knotCount; ++i) {
            result.knots.push_back(knotValues[i]);
            result.multiplicities.push_back(int(multValues[i]));
        }
        wrapPeriodic(result);
        return true;
    };
    const auto analyticSupport = [&](const ParasolidXtAnalyticGeometry& surface,
                                     kernel::AnalyticSurfaceSupport& result) {
        if (surface.type == 67) {
            // SWEPT_SURF, R(u, v) = C(u) + v·D: its section as an edge segment.
            auto section = std::make_shared<kernel::AnalyticEdgeSegment>();
            if (!sectionOf(geometry.value(surface.links.value("section"), nullptr), *section)) return false;
            result = {};
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Swept;
            result.edge = std::move(section);
            result.normal = convert(surface.vectors.value("sweep"));
            return true;
        }
        if (surface.type == 60) {
            const auto* base = geometry.value(surface.links.value("surface"), nullptr);
            if (!base || base->type != 124 ||
                surface.sense != base->sense ||
                surface.bytes.value("check") == 'I' ||
                !std::isfinite(surface.reals.value("offset")) ||
                std::fabs(surface.reals.value("offset")) < 1e-12)
                return false;
            result = {};
            result.kind = kernel::AnalyticSurfaceSupport::Kind::BSplineOffset;
            result.offsetDistance = surface.reals.value("offset") *
                (base->sense == '-' ? -1.0 : 1.0);
            return splineSurface(*base, result.bspline);
        }
        if (surface.type == 124) {
            result = {};
            result.kind = kernel::AnalyticSurfaceSupport::Kind::BSpline;
            return splineSurface(surface, result.bspline);
        }
        if (surface.type < 50 || surface.type > 54) return false;
        result = {};
        if (surface.type == 50)
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Plane;
        else if (surface.type == 51)
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Cylinder;
        else if (surface.type == 52)
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Cone;
        else if (surface.type == 53)
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Sphere;
        else
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Torus;
        const QByteArray originKey = surface.type >= 53 &&
            surface.vectors.contains("centre") ? QByteArrayLiteral("centre")
                                               : QByteArrayLiteral("pvec");
        const QByteArray normalKey = surface.type == 50
            ? QByteArrayLiteral("normal") : QByteArrayLiteral("axis");
        if (!surface.vectors.contains(originKey) ||
            !surface.vectors.contains(normalKey) ||
            !surface.vectors.contains("x_axis")) return false;
        result.origin = convert(surface.vectors.value(originKey));
        result.normal = convert(surface.vectors.value(normalKey));
        result.xAxis = convert(surface.vectors.value("x_axis"));
        result.radius = surface.reals.value("radius");
        result.semiAngle = std::atan2(surface.reals.value("sin_half_angle"),
                                      surface.reals.value("cos_half_angle"));
        result.majorRadius = surface.reals.value("major_radius");
        result.minorRadius = surface.reals.value("minor_radius");
        return true;
    };
    // Rolling-ball blends (BLENDED_EDGE, 56): one definition per surface node, shared by the face
    // on it and by every edge that crosses it or runs along its contact with a support.
    QHash<quint32, const ParasolidXtFin*> finsByIndex;
    QHash<quint32, const ParasolidXtLoop*> loopsByIndex;
    QHash<quint32, const ParasolidXtFace*> facesByIndex;
    for (const auto& fin : topology.fins) finsByIndex.insert(fin.index, &fin);
    for (const auto& loop : topology.loops) loopsByIndex.insert(loop.index, &loop);
    for (const auto& face : topology.faces) facesByIndex.insert(face.index, &face);
    QHash<quint32, std::shared_ptr<const kernel::RollingBallBlend>> blendDefinitions;
    QString blendError;
    // The point halfway along an exact edge (a line, circle or ellipse arc), which tells on a closed
    // spine which way round the blend's face goes.
    const auto middleOf = [&](const ParasolidXtWireSegment& source, cadnext::Vector3& middle) {
        const auto* stored = geometry.value(source.curveIndex, nullptr);
        const auto* curve = stored && stored->type == 133
            ? geometry.value(stored->links.value("basis_curve"), nullptr) : stored;
        if (!curve || !source.hasEndpoints || source.start == source.end) return false;
        if (curve->type == 30) {
            middle = {(source.start[0] + source.end[0]) / 2, (source.start[1] + source.end[1]) / 2,
                      (source.start[2] + source.end[2]) / 2};
            return true;
        }
        if (curve->type != 31 && curve->type != 32) return false;
        const auto c = curve->vectors.value("centre"), n = curve->vectors.value("normal"),
                   x = curve->vectors.value("x_axis");
        const std::array<double, 3> y{n[1] * x[2] - n[2] * x[1], n[2] * x[0] - n[0] * x[2], n[0] * x[1] - n[1] * x[0]};
        const double a = curve->type == 31 ? curve->reals.value("radius") : curve->reals.value("major_radius");
        const double b = curve->type == 31 ? curve->reals.value("radius") : curve->reals.value("minor_radius");
        if (!(a > 0) || !(b > 0)) return false;
        const auto angle = [&](const std::array<double, 3>& p) {
            double along = 0, across = 0;
            for (int i = 0; i < 3; ++i) {
                along += (p[i] - c[i]) * x[i];
                across += (p[i] - c[i]) * y[i];
            }
            return std::atan2(across / b, along / a);
        };
        constexpr double turn = 2 * 3.14159265358979323846;
        const double first = angle(source.start);
        double last = angle(source.end);
        if (source.sense == stored->sense) {
            while (last <= first) last += turn;
        } else {
            while (last >= first) last -= turn;
        }
        const double m = (first + last) / 2;
        middle = {c[0] + a * std::cos(m) * x[0] + b * std::sin(m) * y[0],
                  c[1] + a * std::cos(m) * x[1] + b * std::sin(m) * y[1],
                  c[2] + a * std::cos(m) * x[2] + b * std::sin(m) * y[2]};
        return true;
    };
    const auto blendDefinition = [&](quint32 index) -> std::shared_ptr<const kernel::RollingBallBlend> {
        if (const auto found = blendDefinitions.constFind(index); found != blendDefinitions.cend())
            return found.value();
        const auto refuse = [&](const QString& why) {
            blendError = why;
            blendDefinitions.insert(index, nullptr);
            return std::shared_ptr<const kernel::RollingBallBlend>();
        };
        const auto* blend = geometry.value(index, nullptr);
        if (!blend || blend->type != 56)
            return refuse(QObject::tr("узел %1 не является поверхностью скругления").arg(index));
        const char blendType = blend->bytes.value("blend_type");
        if (blendType != 'R' && blendType != 'E')
            return refuse(QObject::tr("скругление %1 не катящимся шаром постоянного радиуса (тип «%2») — "
                                      "его построение в XT Format Reference не описано")
                              .arg(index).arg(QChar(blendType)));
        const auto range = blend->realArrays.value("range");
        const auto supports = blend->linkArrays.value("surface");
        if (range.size() != 2 || supports.size() != 2)
            return refuse(QObject::tr("у скругления %1 нет двух опор и двух смещений").arg(index));
        const double radius = std::fabs(range[0]);
        if (!(radius > 0) || std::fabs(std::fabs(range[1]) - radius) > 1e-9 * radius)
            return refuse(QObject::tr("скругление %1 со смещениями %2 и %3: переменный радиус не поддерживается")
                              .arg(index).arg(range[0]).arg(range[1]));
        // A blend's start/end LIMITs bound a periodic spine where the blended edge has terminators;
        // the faces' own edges bound the surface here, so they are not needed.
        auto definition = std::make_shared<kernel::RollingBallBlend>();
        definition->radius = radius;
        // A sharp edge the ball touches instead of a surface: in XT (type 'E', read from the NIST MTC
        // box and Bell_Crank.x_b) a support that is itself a blend of zero range, whose spine is the
        // edge — its offset by the radius, a tube round the edge, is one of the spine's surfaces.
        const auto edgeOf = [&](const ParasolidXtAnalyticGeometry& degenerate, kernel::AnalyticSurfaceSupport& result) {
            const auto zero = degenerate.realArrays.value("range");
            const auto* curve = geometry.value(degenerate.links.value("spine"), nullptr);
            if (zero.size() != 2 || zero[0] != 0.0 || zero[1] != 0.0 || !curve) return false;
            auto edge = std::make_shared<kernel::AnalyticEdgeSegment>();
            if (curve->type == 30) {
                edge->kind = kernel::AnalyticEdgeKind::Line;
                edge->center = convert(curve->vectors.value("pvec"));
                edge->normal = convert(curve->vectors.value("direction"));
            } else if (curve->type == 31 || curve->type == 32) {
                edge->kind = curve->type == 31 ? kernel::AnalyticEdgeKind::Circle : kernel::AnalyticEdgeKind::Ellipse;
                edge->center = convert(curve->vectors.value("centre"));
                edge->normal = convert(curve->vectors.value("normal"));
                edge->xAxis = convert(curve->vectors.value("x_axis"));
                edge->radius = curve->reals.value("radius");
                edge->majorRadius = curve->reals.value("major_radius");
                edge->minorRadius = curve->reals.value("minor_radius");
            } else if (curve->type == 134) {
                edge->kind = kernel::AnalyticEdgeKind::BSpline;
                if (!splineCurve(*curve, edge->bspline)) return false;
            } else {
                return false;
            }
            result = {};
            result.kind = kernel::AnalyticSurfaceSupport::Kind::Edge;
            result.edge = std::move(edge);
            return true;
        };
        int edges = 0;
        for (int i = 0; i < 2; ++i) {
            const auto* support = geometry.value(supports[i], nullptr);
            if (support && support->type == 56 && edgeOf(*support, definition->supports[i])) {
                ++edges;
                definition->offsets[i] = radius; // from an edge: a distance, never negative
                continue;
            }
            if (!support || !analyticSupport(*support, definition->supports[i]))
                return refuse(QObject::tr("опора %1 скругления %2 — пока не поддерживаемая поверхность")
                                  .arg(i + 1).arg(index));
            // XT range: the offset along the support as its sense turns it.
            definition->offsets[i] = range[i] * (support->sense == '-' ? -1.0 : 1.0);
        }
        if (blendType == 'E' && edges != 1)
            return refuse(QObject::tr("скругление %1 типа «E» без опоры-ребра — его построение не описано").arg(index));
        const auto* spine = geometry.value(blend->links.value("spine"), nullptr);
        auto& s = definition->spine;
        if (spine && spine->type == 30) {
            s.kind = kernel::AnalyticEdgeKind::Line;
            s.center = convert(spine->vectors.value("pvec"));
            s.normal = convert(spine->vectors.value("direction"));
        } else if (spine && (spine->type == 31 || spine->type == 32)) {
            s.kind = spine->type == 31 ? kernel::AnalyticEdgeKind::Circle : kernel::AnalyticEdgeKind::Ellipse;
            s.center = convert(spine->vectors.value("centre"));
            s.normal = convert(spine->vectors.value("normal"));
            s.xAxis = convert(spine->vectors.value("x_axis"));
            s.radius = spine->reals.value("radius");
            s.majorRadius = spine->reals.value("major_radius");
            s.minorRadius = spine->reals.value("minor_radius");
        } else if (spine && spine->type == 134) {
            s.kind = kernel::AnalyticEdgeKind::BSpline;
            if (!splineCurve(*spine, s.bspline))
                return refuse(QObject::tr("B-сплайн спины скругления %1 некорректен").arg(index));
        } else if (spine && spine->type == 38) {
            s.kind = kernel::AnalyticEdgeKind::SurfaceIntersection;
            const auto surfaces = spine->linkArrays.value("surface");
            for (int i = 0; i < 2; ++i) {
                const auto* surface = surfaces.size() == 2 ? geometry.value(surfaces[i], nullptr) : nullptr;
                if (!surface || !analyticSupport(*surface, s.intersectionSurfaces[i]))
                    return refuse(QObject::tr("спина скругления %1 — пересечение пока не поддерживаемых поверхностей")
                                      .arg(index));
            }
            const auto* chart = geometry.value(spine->links.value("chart"), nullptr);
            const auto points = chart ? chart->realArrays.value("Hvec") : std::vector<double>();
            for (std::size_t i = 0; i + 2 < points.size(); i += 3)
                definition->spineChart.push_back({points[i], points[i + 1], points[i + 2]});
            if (definition->spineChart.size() < 2)
                return refuse(QObject::tr("у спины скругления %1 нет карты точек").arg(index));
            const auto* start = geometry.value(spine->links.value("start"), nullptr);
            definition->spineClosed = start && start->bytes.value("type") == 'H';
            // A terminator limit holds the singular point itself and then the chart's branch point
            // next to it: the spine runs on to the singular point, where the blend narrows to nothing.
            for (int end = 0; end < 2; ++end) {
                const auto* limit = geometry.value(spine->links.value(end == 0 ? "start" : "end"), nullptr);
                const auto hvec = limit ? limit->realArrays.value("hvec") : std::vector<double>();
                if (!limit || limit->bytes.value("type") != 'T' || hvec.size() < 3) continue;
                const cadnext::Vector3 singular{hvec[0], hvec[1], hvec[2]};
                auto& chart = definition->spineChart;
                const auto& near = end == 0 ? chart.front() : chart.back();
                if (std::hypot(near.x - singular.x, near.y - singular.y, near.z - singular.z) < 1e-12) continue;
                if (end == 0) chart.insert(chart.begin(), singular);
                else chart.push_back(singular);
                definition->spineTerminators[end] = true;
            }
        } else {
            return refuse(QObject::tr("спина скругления %1 — пока не поддерживаемая кривая (тип %2)")
                              .arg(index).arg(spine ? spine->type : 0));
        }
        // Where the faces on this blend are, and which way the support faces next to them turn.
        for (const auto& face : topology.faces) {
            if (face.surfaceIndex != index) continue;
            for (const auto* wire : faceWires.value(face.index)) {
                for (const auto& source : wire->segments) {
                    if (source.hasEndpoints && !(source.edgeIndex == 0 && source.curveIndex == 0)) {
                        std::vector<cadnext::Vector3> edge{convert(source.start)};
                        cadnext::Vector3 middle;
                        if (middleOf(source, middle)) edge.push_back(middle);
                        edge.push_back(convert(source.end));
                        definition->faceEdges.push_back(std::move(edge));
                    }
                    const auto* fin = finsByIndex.value(source.finIndex, nullptr);
                    const auto* other = fin ? finsByIndex.value(fin->otherIndex, nullptr) : nullptr;
                    const auto* loop = other ? loopsByIndex.value(other->loopIndex, nullptr) : nullptr;
                    const auto* neighbour = loop ? facesByIndex.value(loop->faceIndex, nullptr) : nullptr;
                    for (int b = 0; b < 2 && neighbour; ++b) {
                        const auto* support = geometry.value(supports[b], nullptr);
                        if (neighbour->surfaceIndex == supports[b] && support)
                            definition->supportFaceSense[b] =
                                (neighbour->sense == '-') != (support->sense == '-') ? -1 : 1;
                    }
                }
            }
        }
        blendDefinitions.insert(index, definition);
        return definition;
    };
    // A surface an intersection edge lies on: an exact one, or a blend.
    const auto supportOf = [&](const ParasolidXtAnalyticGeometry& surface,
                               kernel::AnalyticSurfaceSupport& result) {
        if (surface.type != 56) return analyticSupport(surface, result);
        result = {};
        result.kind = kernel::AnalyticSurfaceSupport::Kind::Blend;
        result.blend = blendDefinition(surface.index);
        return bool(result.blend);
    };
    for (const auto& item : topology.analyticGeometry) {
        if (item.type == 124) {
            kernel::BSplineSurfaceDefinition definition;
            if (!splineSurface(item, definition)) {
                error = QObject::tr("Некорректное определение B-сплайн поверхности XT %1.")
                            .arg(item.index);
                return false;
            }
        } else if (item.type == 134) {
            // A 2D B-curve lives in a surface's parameter space as the basis of an SP-curve
            // (vertex_dim 2, or 3 when rational); it is not a 3D edge curve and is not checked as one.
            if (const auto* nurbs = geometry.value(item.links.value("nurbs"), nullptr)) {
                const quint32 dimension = nurbs->integers.value("vertex_dim");
                const bool rational = nurbs->bytes.value("rational") != 0;
                if ((!rational && dimension == 2) || (rational && dimension == 3)) continue;
            }
            kernel::BSplineCurveDefinition definition;
            if (!splineCurve(item, definition)) {
                error = QObject::tr("Некорректное определение B-сплайн кривой XT %1.")
                            .arg(item.index);
                return false;
            }
        }
    }
    // The loops of a face as exact boundary segments.
    const auto appendLoops = [&](const ParasolidXtFace& face, kernel::AnalyticFacePatch& patch) {
        const auto loops = faceWires.value(face.index);
        if (loops.empty()) {
            error = QObject::tr("У грани %1 нет контуров.").arg(face.index);
            return false;
        }
        for (const auto* wire : loops) {
            std::vector<kernel::AnalyticEdgeSegment> segments;
            segments.reserve(wire->segments.size());
            for (const auto& source : wire->segments) {
                // Parasolid represents a pole or a collapsed seam as a
                // point-only FIN (edge/curve index 0). Analytic OCCT faces
                // generate the corresponding degenerate boundary themselves.
                if (source.edgeIndex == 0 && source.curveIndex == 0 &&
                    source.hasEndpoints && source.start == source.end)
                    continue;
                // A TRIMMED_CURVE is its basis curve between two points; the edge runs along the
                // trimmed curve, whose natural direction is the basis's, parm_1 to parm_2.
                const auto* stored = geometry.value(source.curveIndex, nullptr);
                const auto* curve = stored;
                if (stored && stored->type == 133)
                    curve = geometry.value(stored->links.value("basis_curve"), nullptr);
                if (!curve || (curve->type != 30 && curve->type != 31 &&
                               curve->type != 32 && curve->type != 38 &&
                               curve->type != 134 && curve->type != 137)) {
                    error = QObject::tr("Контур грани %1 использует неподдерживаемую кривую (тип %2).")
                                .arg(face.index).arg(curve ? curve->type : 0);
                    return false;
                }
                kernel::AnalyticEdgeSegment segment;
                if (source.finCurve) segment.sourceId = source.edgeIndex;
                if (std::isfinite(source.tolerance)) segment.tolerance = source.tolerance;
                if (curve->type == 137) {
                    // SP_CURVE: a 2D B-curve in its surface's (u, v), trimmed by the TRIMMED_CURVE
                    // around it (parm_1 to parm_2 are the SP-curve's own parameters).
                    const auto* surface = geometry.value(curve->links.value("surface"), nullptr);
                    const auto* planar = geometry.value(curve->links.value("b_curve"), nullptr);
                    if (surface && surface->type == 52) {
                        error = QObject::tr("SP-кривая грани %1 лежит на конусе: параметризация конуса XT не установлена — "
                                            "нет данных.").arg(face.index);
                        return false;
                    }
                    if (!surface || !planar || !analyticSupport(*surface, segment.intersectionSurfaces[0]) ||
                        !planeCurve(*planar, segment.bspline)) {
                        error = QObject::tr("SP-кривая грани %1 на пока не поддерживаемой поверхности или кривой.")
                                    .arg(face.index);
                        return false;
                    }
                    segment.kind = kernel::AnalyticEdgeKind::SurfaceCurve;
                    if (curve->links.value("surface") == face.surfaceIndex) {
                        segment.pcurve = segment.bspline;
                        segment.pcurveIndependentParameter = true;
                    }
                    if (stored != curve) {
                        segment.curveFirst = stored->reals.value("parm_1");
                        segment.curveLast = stored->reals.value("parm_2");
                    }
                    segment.forward = source.sense == stored->sense;
                    segment.start = convert(source.start);
                    segment.end = convert(source.end);
                    segment.hasEndpoints = source.hasEndpoints;
                    segments.push_back(segment);
                    continue;
                }
                if (curve->type == 30)
                    segment.kind = kernel::AnalyticEdgeKind::Line;
                else if (curve->type == 31)
                    segment.kind = kernel::AnalyticEdgeKind::Circle;
                else if (curve->type == 32)
                    segment.kind = kernel::AnalyticEdgeKind::Ellipse;
                else if (curve->type == 38)
                    segment.kind = kernel::AnalyticEdgeKind::SurfaceIntersection;
                else
                    segment.kind = kernel::AnalyticEdgeKind::BSpline;
                // FIN sense is relative to the stored curve's own sense, not
                // directly to its mathematical circle parameter direction.
                segment.forward = source.sense == stored->sense;
                segment.start = convert(source.start);
                segment.end = convert(source.end);
                segment.hasEndpoints = source.hasEndpoints;
                if (stored != curve && curve->type == 134 && curve->sense == '+') {
                    segment.curveFirst = stored->reals.value("parm_1");
                    segment.curveLast = stored->reals.value("parm_2");
                }
                if (stored != curve && !source.hasEndpoints) {
                    // A ring edge on a trimmed curve: its ends are the trim points.
                    const auto first = convert(stored->vectors.value("point_1"));
                    const auto second = convert(stored->vectors.value("point_2"));
                    segment.start = segment.forward ? first : second;
                    segment.end = segment.forward ? second : first;
                    segment.hasEndpoints = true;
                }
                if (curve->type == 31) {
                    segment.center = convert(curve->vectors.value("centre"));
                    segment.normal = convert(curve->vectors.value("normal"));
                    segment.xAxis = convert(curve->vectors.value("x_axis"));
                    segment.radius = curve->reals.value("radius");
                } else if (curve->type == 32) {
                    segment.center = convert(curve->vectors.value("centre"));
                    segment.normal = convert(curve->vectors.value("normal"));
                    segment.xAxis = convert(curve->vectors.value("x_axis"));
                    segment.majorRadius = curve->reals.value("major_radius");
                    segment.minorRadius = curve->reals.value("minor_radius");
                } else if (curve->type == 38) {
                    const auto supports = curve->linkArrays.value("surface");
                    if (supports.size() != 2) {
                        error = QObject::tr("Кривая пересечения грани %1 не содержит двух опорных поверхностей.")
                                    .arg(face.index);
                        return false;
                    }
                    // Where a blend touches a support, XT intersects the support with a BLEND_BOUND
                    // (59) that only names the blend and the support: the contact line itself.
                    int bound = -1;
                    for (int i = 0; i < 2; ++i) {
                        const auto* support = geometry.value(supports[i], nullptr);
                        if (support && support->type == 59) bound = i;
                    }
                    if (bound >= 0) {
                        const auto* marker = geometry.value(supports[bound], nullptr);
                        // The support touched is the curve's other surface. (The BLEND_BOUND's own
                        // `boundary` field, "index into supporting surface array", was 1 − that
                        // index on all 52 contact lines of the NIST parts, so it is not relied on.)
                        const quint32 blendIndex = marker->links.value("blend");
                        const auto* blend = geometry.value(blendIndex, nullptr);
                        const auto blendSupports = blend ? blend->linkArrays.value("surface")
                                                         : std::vector<quint32>();
                        int boundary = -1;
                        for (int b = 0; b < int(blendSupports.size()) && blendSupports.size() == 2; ++b)
                            if (blendSupports[b] == supports[1 - bound]) boundary = b;
                        if (boundary < 0) {
                            error = QObject::tr("Граница скругления в контуре грани %1 не указывает на свою опору.")
                                        .arg(face.index);
                            return false;
                        }
                        segment.kind = kernel::AnalyticEdgeKind::BlendBoundary;
                        segment.blend = blendDefinition(blendIndex);
                        segment.blendBoundary = boundary;
                        if (!segment.blend) {
                            error = QObject::tr("Скругление у грани %1: %2.").arg(face.index).arg(blendError);
                            return false;
                        }
                    }
                    if (const auto* chart = geometry.value(curve->links.value("chart"), nullptr)) {
                        const auto points = chart->realArrays.value("Hvec");
                        if (points.size() >= 3) {
                            segment.hasBranchPoint = true;
                            segment.branchPoint = {points[0], points[1], points[2]};
                        }
                        for (std::size_t i = 0; i + 2 < points.size(); i += 3)
                            segment.chart.push_back({points[i], points[i + 1], points[i + 2]});
                        // As for a blend's spine: closed by an 'H' start, a terminator's singular point
                        // added at its end.
                        const auto* start = geometry.value(curve->links.value("start"), nullptr);
                        segment.chartClosed = start && start->bytes.value("type") == 'H';
                        for (int end = 0; end < 2 && !segment.chart.empty(); ++end) {
                            const auto* limit = geometry.value(curve->links.value(end == 0 ? "start" : "end"), nullptr);
                            const auto hvec = limit ? limit->realArrays.value("hvec") : std::vector<double>();
                            if (!limit || limit->bytes.value("type") != 'T' || hvec.size() < 3) continue;
                            const cadnext::Vector3 singular{hvec[0], hvec[1], hvec[2]};
                            const auto& near = end == 0 ? segment.chart.front() : segment.chart.back();
                            if (std::hypot(near.x - singular.x, near.y - singular.y, near.z - singular.z) < 1e-12) continue;
                            if (end == 0) segment.chart.insert(segment.chart.begin(), singular);
                            else segment.chart.push_back(singular);
                            segment.chartTerminators[end] = true;
                        }
                    }
                    for (std::size_t i = 0; i < 2 && bound < 0; ++i) {
                        const auto* support = geometry.value(supports[i], nullptr);
                        if (!support ||
                            !supportOf(*support, segment.intersectionSurfaces[i])) {
                            error = support && support->type == 56 && !blendError.isEmpty()
                                ? QObject::tr("Скругление у грани %1: %2.").arg(face.index).arg(blendError)
                                : QObject::tr("Кривая пересечения грани %1 требует пока не поддерживаемую пару поверхностей.")
                                      .arg(face.index);
                            return false;
                        }
                    }
                } else if (curve->type == 134 && !splineCurve(*curve, segment.bspline)) {
                    error = QObject::tr("Не удалось восстановить точную B-сплайн кривую грани %1.")
                                .arg(face.index);
                    return false;
                }
                segments.push_back(segment);
            }
            if (!segments.empty()) patch.loops.push_back(std::move(segments));
        }
        if (patch.loops.empty()) {
            error = QObject::tr("У грани %1 не осталось геометрического контура после удаления точечных швов.")
                        .arg(face.index);
            return false;
        }
        return true;
    };
    for (const auto& face : topology.faces) {
        const auto* surface = geometry.value(face.surfaceIndex, nullptr);
        if (surface && surface->type == 56) {
            // BLENDED_EDGE: the kernel builds its surface from the definition, within 1e-6 m.
            kernel::AnalyticFacePatch patch;
            patch.kind = kernel::AnalyticFacePatch::Kind::Blend;
            patch.blend = blendDefinition(surface->index);
            if (!patch.blend) {
                error = QObject::tr("Скругление грани %1: %2.").arg(face.index).arg(blendError);
                return false;
            }
            patch.normal = {0, 0, 1};
            patch.xAxis = {1, 0, 0};
            patch.reversed = (face.sense == '-') != (surface->sense == '-');
            if (!appendLoops(face, patch)) return false;
            patches.push_back(std::move(patch));
            continue;
        }
        if (surface && surface->type == 67) {
            // SWEPT_SURF: built from its section curve and direction, trimmed by the loops.
            kernel::AnalyticFacePatch patch;
            patch.kind = kernel::AnalyticFacePatch::Kind::Swept;
            if (!sectionOf(geometry.value(surface->links.value("section"), nullptr), patch.section)) {
                error = QObject::tr("Сечение поверхности выдавливания грани %1 — пока не поддерживаемая кривая.").arg(face.index);
                return false;
            }
            patch.sweep = convert(surface->vectors.value("sweep"));
            patch.normal = {0, 0, 1}; // no frame of its own; the builder needs a valid one
            patch.xAxis = {1, 0, 0};
            patch.reversed = (face.sense == '-') != (surface->sense == '-');
            if (!appendLoops(face, patch)) return false;
            patches.push_back(std::move(patch));
            continue;
        }
        if (!surface || (surface->type != 50 && surface->type != 51 &&
                         surface->type != 52 && surface->type != 53 &&
                         surface->type != 54 && surface->type != 124 &&
                         surface->type != 60)) {
            error = QObject::tr("Грань %1 использует пока не поддерживаемую поверхность.")
                        .arg(face.index);
            return false;
        }
        kernel::AnalyticFacePatch patch;
        if (surface->type == 50)
            patch.kind = kernel::AnalyticFacePatch::Kind::Plane;
        else if (surface->type == 51)
            patch.kind = kernel::AnalyticFacePatch::Kind::Cylinder;
        else if (surface->type == 52)
            patch.kind = kernel::AnalyticFacePatch::Kind::Cone;
        else if (surface->type == 53)
            patch.kind = kernel::AnalyticFacePatch::Kind::Sphere;
        else if (surface->type == 54)
            patch.kind = kernel::AnalyticFacePatch::Kind::Torus;
        else if (surface->type == 60)
            patch.kind = kernel::AnalyticFacePatch::Kind::BSplineOffset;
        else
            patch.kind = kernel::AnalyticFacePatch::Kind::BSpline;
        if (surface->type == 124) {
            if (!splineSurface(*surface, patch.bspline)) {
                error = QObject::tr("Не удалось восстановить точную B-сплайн поверхность грани %1.")
                            .arg(face.index);
                return false;
            }
            patch.normal = {0, 0, 1};
            patch.xAxis = {1, 0, 0};
        }
        if (surface->type == 60) {
            kernel::AnalyticSurfaceSupport offset;
            if (!analyticSupport(*surface, offset)) {
                error = QObject::tr("Не удалось восстановить точную поверхность смещения грани %1.")
                            .arg(face.index);
                return false;
            }
            patch.bspline = std::move(offset.bspline);
            patch.offsetDistance = offset.offsetDistance;
            patch.normal = {0, 0, 1};
            patch.xAxis = {1, 0, 0};
        }
        const QByteArray originKey = (surface->type == 53 || surface->type == 54)
                                                         ? QByteArrayLiteral("centre")
                                                         : QByteArrayLiteral("pvec");
        patch.origin = convert(surface->vectors.value(originKey));
        if (surface->type == 53 && !surface->vectors.contains("centre"))
            patch.origin = convert(surface->vectors.value("pvec"));
        const QByteArray normalKey = surface->type == 50
            ? QByteArrayLiteral("normal") : QByteArrayLiteral("axis");
        if (surface->type != 124 && surface->type != 60) {
            patch.normal = convert(surface->vectors.value(normalKey));
            patch.xAxis = surface->vectors.contains("x_axis")
                ? convert(surface->vectors.value("x_axis")) : cadnext::Vector3{1, 0, 0};
        }
        if (surface->type == 52) {
            patch.semiAngle = std::atan2(surface->reals.value("sin_half_angle"),
                                         surface->reals.value("cos_half_angle"));
            patch.radius = surface->reals.value("radius");
        } else if (surface->type == 53) {
            patch.radius = surface->reals.value("radius");
        } else if (surface->type == 54) {
            patch.majorRadius = surface->reals.value("major_radius");
            patch.minorRadius = surface->reals.value("minor_radius");
        } else {
            patch.radius = surface->reals.value("radius");
        }
        // XT Format Reference, "Curve and Surface Senses": the face normal is parallel to the
        // natural surface normal if neither or both of face->sense and surface->sense are
        // negative. The surface's own sense takes part as the curve's does for fins below.
        patch.reversed = (face.sense == '-') != (surface->sense == '-');
        if (!appendLoops(face, patch)) return false;
        patches.push_back(std::move(patch));
    }
    std::vector<quint32> patchFaces;
    for (const auto& face : topology.faces) patchFaces.push_back(face.index);
    kernel::AnalyticSolidReport built;
    const auto solid = kernel.makeAnalyticSolid(patches, &built);
    if (!solid.isOk()) {
        error = QObject::tr("Грани Parasolid XT не образуют проверенное точное тело: %1")
                    .arg(QString::fromStdString(solid.error().message));
        return false;
    }
    if (report) {
        for (const auto& face : built.approximated)
            report->approximated.push_back({face.patchIndex < patchFaces.size() ? patchFaces[face.patchIndex] : 0,
                                            face.deviation, face.contactGap});
        report->tolerantEdges += int(std::count_if(topology.edges.begin(), topology.edges.end(),
                                                   [](const ParasolidXtEdge& edge) { return std::isfinite(edge.tolerance); }));
        report->largestEdgeTolerance = std::max(report->largestEdgeTolerance, built.largestEdgeTolerance);
        for (const auto& face : built.split)
            report->split.push_back({face.patchIndex < patchFaces.size() ? patchFaces[face.patchIndex] : 0, face.faces, {}});
    }
    shape = solid.value();
    error.clear();
    return true;
}

bool readSolidWorksPlanarAssembly(const QString& path, kernel::OcctKernel& kernel,
                                 std::vector<SolidWorksImportedBody>& bodies,
                                 QString& error) {
    bodies.clear();
    std::vector<SolidWorksAssemblyComponent> components;
    if (!readSolidWorksAssemblyComponents(path, components, error)) return false;
    if (components.empty()) {
        error = QObject::tr("Сборка SOLIDWORKS не содержит компонентов.");
        return false;
    }
    const QDir directory = QFileInfo(path).dir();
    QHash<QString, std::vector<kernel::PlanarFacePatch>> cache;
    for (const auto& component : components) {
        if (component.virtualComponent) {
            error = QObject::tr("Встроенный компонент %1 пока нельзя извлечь "
                                "как точное тело.").arg(component.name);
            bodies.clear();
            return false;
        }
        QString normalized = component.sourcePath;
        normalized.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const QString fileName = normalized.section(QLatin1Char('/'), -1);
        const QString partPath = directory.filePath(fileName);
        if (fileName.isEmpty() ||
            QFileInfo(fileName).suffix().compare(QLatin1String("sldprt"),
                                              Qt::CaseInsensitive) != 0 ||
            !QFileInfo::exists(partPath)) {
            error = QObject::tr("Для компонента %1 требуется файл %2 рядом со сборкой.")
                        .arg(component.name, fileName);
            bodies.clear();
            return false;
        }
        const QString key = configurationKey(partPath, component.configuration);
        if (!cache.contains(key)) {
            std::vector<kernel::PlanarFacePatch> patches;
            if (!readPlanarPatches(partPath, patches, error, component.configuration)) {
                error = QObject::tr("Компонент %1: %2").arg(component.name, error);
                bodies.clear();
                return false;
            }
            cache.insert(key, std::move(patches));
        }
        auto patches = cache.value(key);
        if (!transformPatches(patches, component.transform)) {
            error = QObject::tr("Некорректная матрица положения компонента %1.")
                        .arg(component.name);
            bodies.clear();
            return false;
        }
        const auto solid = kernel.makePlanarSolid(patches);
        if (!solid.isOk()) {
            error = QObject::tr("Не удалось собрать точное тело компонента %1: %2")
                        .arg(component.name,
                             QString::fromStdString(solid.error().message));
            bodies.clear();
            return false;
        }
        const QString name = component.name.isEmpty()
            ? QFileInfo(fileName).completeBaseName() : component.name;
        bodies.push_back({name, solid.value()});
    }
    error.clear();
    return true;
}

bool readSolidWorksAnalyticAssembly(const QString& path, kernel::OcctKernel& kernel,
                                   std::vector<SolidWorksImportedBody>& bodies,
                                   QString& error, ParasolidXtBuildReport* report) {
    bodies.clear();
    if (report) *report = {};
    std::vector<SolidWorksAssemblyComponent> components;
    if (!readSolidWorksAssemblyComponents(path, components, error)) return false;
    if (components.empty()) {
        error = QObject::tr("Сборка SOLIDWORKS не содержит компонентов.");
        return false;
    }
    const QDir directory = QFileInfo(path).dir();
    QHash<QString, kernel::ShapeHandle> cache;
    for (const auto& component : components) {
        if (component.virtualComponent) {
            error = QObject::tr("Встроенный компонент %1 пока нельзя извлечь "
                                "как точное тело.").arg(component.name);
            bodies.clear();
            return false;
        }
        QString normalized = component.sourcePath;
        normalized.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const QString fileName = normalized.section(QLatin1Char('/'), -1);
        const QString partPath = directory.filePath(fileName);
        if (fileName.isEmpty() ||
            QFileInfo(fileName).suffix().compare(QLatin1String("sldprt"),
                                              Qt::CaseInsensitive) != 0 ||
            !QFileInfo::exists(partPath)) {
            error = QObject::tr("Для компонента %1 требуется файл %2 рядом со сборкой.")
                        .arg(component.name, fileName);
            bodies.clear();
            return false;
        }
        const QString key = configurationKey(partPath, component.configuration);
        if (!cache.contains(key)) {
            kernel::ShapeHandle partShape;
            ParasolidXtBuildReport partReport;
            if (!readSolidWorksAnalyticPart(partPath, kernel, partShape, error, &partReport, component.configuration)) {
                error = QObject::tr("Компонент %1: %2").arg(component.name, error);
                bodies.clear();
                return false;
            }
            if (report) {
                for (auto face : partReport.approximated) {
                    face.body = fileName;
                    report->approximated.push_back(face);
                }
                report->tolerantEdges += partReport.tolerantEdges;
                report->largestEdgeTolerance = std::max(report->largestEdgeTolerance, partReport.largestEdgeTolerance);
                for (auto face : partReport.split) {
                    face.body = fileName;
                    report->split.push_back(face);
                }
            }
            cache.insert(key, partShape);
        }
        const auto instance = kernel.transformShape(cache.value(key),
                                                    component.transform);
        if (!instance.isOk()) {
            error = QObject::tr("Некорректное положение компонента %1: %2")
                        .arg(component.name,
                             QString::fromStdString(instance.error().message));
            bodies.clear();
            return false;
        }
        const QString name = component.name.isEmpty()
            ? QFileInfo(fileName).completeBaseName() : component.name;
        bodies.push_back({name, instance.value()});
    }
    error.clear();
    return true;
}

bool readSolidWorksAssemblyProduct(const QString& path, kernel::OcctKernel& kernel,
                                   kernel::ProductStructure& product, QString& error,
                                   ParasolidXtBuildReport* report, const ImportProgress* progress) {
    product = {};
    if (report) *report = {};
    std::vector<SolidWorksAssemblyComponent> components;
    if (!readSolidWorksAssemblyComponents(path, components, error)) return false;
    if (components.empty()) {
        error = QObject::tr("Сборка SOLIDWORKS не содержит компонентов.");
        return false;
    }
    const QDir directory = QFileInfo(path).dir();
    QHash<QString, int> parts; // SLDPRT path and configuration -> part index
    // How many distinct parts there are to build, for the progress.
    QSet<QString> distinct;
    for (const auto& component : components) {
        QString normalized = component.sourcePath;
        normalized.replace(QLatin1Char('\\'), QLatin1Char('/'));
        distinct.insert(configurationKey(normalized.section(QLatin1Char('/'), -1).toLower(), component.configuration));
    }
    kernel::ProductAssembly root;
    root.name = QFileInfo(path).completeBaseName().toStdString();
    for (const auto& component : components) {
        if (component.virtualComponent) {
            error = QObject::tr("Встроенный компонент %1 пока нельзя извлечь "
                                "как точное тело.").arg(component.name);
            return false;
        }
        QString normalized = component.sourcePath;
        normalized.replace(QLatin1Char('\\'), QLatin1Char('/'));
        const QString fileName = normalized.section(QLatin1Char('/'), -1);
        const QString partPath = directory.filePath(fileName);
        if (fileName.isEmpty() ||
            QFileInfo(fileName).suffix().compare(QLatin1String("sldprt"), Qt::CaseInsensitive) != 0 ||
            !QFileInfo::exists(partPath)) {
            error = QObject::tr("Для компонента %1 требуется файл %2 рядом со сборкой.")
                        .arg(component.name, fileName);
            return false;
        }
        const QString key = configurationKey(partPath, component.configuration);
        if (!parts.contains(key)) {
            if (progress) {
                if (progress->cancelled()) {
                    error = importCancelledReason();
                    return false;
                }
                progress->report(int(product.parts.size()), int(distinct.size()),
                                 QObject::tr("Деталь %1 из %2: %3")
                                     .arg(product.parts.size() + 1)
                                     .arg(distinct.size())
                                     .arg(QFileInfo(fileName).completeBaseName()));
            }
            kernel::ShapeHandle shape;
            ParasolidXtBuildReport partReport;
            if (!readSolidWorksAnalyticPart(partPath, kernel, shape, error, &partReport, component.configuration)) {
                error = QObject::tr("Компонент %1: %2").arg(component.name, error);
                return false;
            }
            if (report) mergeBuildReport(*report, partReport, fileName);
            kernel::ProductPart part;
            part.name = QFileInfo(fileName).completeBaseName().toStdString();
            part.shape = shape;
            parts.insert(key, int(product.parts.size()));
            product.parts.push_back(std::move(part));
        }
        kernel::ProductInstance instance;
        instance.name = (component.name.isEmpty() ? QFileInfo(fileName).completeBaseName() : component.name).toStdString();
        instance.definition = parts.value(key);
        // The matrix as the kernel takes it: columns the images of the axes, the translation at 12..14.
        // A rotation when its columns are orthonormal and right-handed (to 1e-9, rounding of stored
        // doubles) with no projective row; then as a unit quaternion (w, x, y, z).
        const auto& m = component.transform;
        const double c[3][3] = {{m[0], m[1], m[2]}, {m[4], m[5], m[6]}, {m[8], m[9], m[10]}};
        const auto dot = [&](int a, int b) { return c[a][0] * c[b][0] + c[a][1] * c[b][1] + c[a][2] * c[b][2]; };
        const double determinant = c[0][0] * (c[1][1] * c[2][2] - c[1][2] * c[2][1]) -
                                   c[1][0] * (c[0][1] * c[2][2] - c[0][2] * c[2][1]) +
                                   c[2][0] * (c[0][1] * c[1][2] - c[0][2] * c[1][1]);
        bool rigid = m[3] == 0.0 && m[7] == 0.0 && m[11] == 0.0 && m[15] == 1.0 && determinant > 0.0;
        for (int a = 0; a < 3 && rigid; ++a)
            for (int b = 0; b < 3 && rigid; ++b) rigid = std::fabs(dot(a, b) - (a == b ? 1.0 : 0.0)) <= 1e-9;
        if (rigid) {
            // R(i, j) = column j, row i.
            const auto r = [&](int i, int j) { return c[j][i]; };
            const double trace = r(0, 0) + r(1, 1) + r(2, 2);
            double w, x, y, z;
            if (trace > 0.0) {
                const double t = 2.0 * std::sqrt(trace + 1.0);
                w = 0.25 * t;
                x = (r(2, 1) - r(1, 2)) / t;
                y = (r(0, 2) - r(2, 0)) / t;
                z = (r(1, 0) - r(0, 1)) / t;
            } else if (r(0, 0) > r(1, 1) && r(0, 0) > r(2, 2)) {
                const double t = 2.0 * std::sqrt(1.0 + r(0, 0) - r(1, 1) - r(2, 2));
                w = (r(2, 1) - r(1, 2)) / t;
                x = 0.25 * t;
                y = (r(0, 1) + r(1, 0)) / t;
                z = (r(0, 2) + r(2, 0)) / t;
            } else if (r(1, 1) > r(2, 2)) {
                const double t = 2.0 * std::sqrt(1.0 + r(1, 1) - r(0, 0) - r(2, 2));
                w = (r(0, 2) - r(2, 0)) / t;
                x = (r(0, 1) + r(1, 0)) / t;
                y = 0.25 * t;
                z = (r(1, 2) + r(2, 1)) / t;
            } else {
                const double t = 2.0 * std::sqrt(1.0 + r(2, 2) - r(0, 0) - r(1, 1));
                w = (r(1, 0) - r(0, 1)) / t;
                x = (r(0, 2) + r(2, 0)) / t;
                y = (r(1, 2) + r(2, 1)) / t;
                z = 0.25 * t;
            }
            const double norm = std::sqrt(w * w + x * x + y * y + z * z);
            instance.placement.rotation = {w / norm, x / norm, y / norm, z / norm};
            instance.placement.translation = {m[12], m[13], m[14]};
        } else {
            const auto baked = kernel.transformShape(product.parts[std::size_t(instance.definition)].shape, m);
            if (!baked.isOk()) {
                error = QObject::tr("Некорректное положение компонента %1: %2")
                            .arg(component.name, QString::fromStdString(baked.error().message));
                return false;
            }
            kernel::ProductPart part;
            part.name = product.parts[std::size_t(instance.definition)].name + " (отражение или масштаб)";
            part.shape = baked.value();
            instance.definition = int(product.parts.size());
            product.parts.push_back(std::move(part));
            product.warnings.push_back("вхождение «" + instance.name + "» с отражением или масштабом записано отдельной деталью");
        }
        root.instances.push_back(std::move(instance));
    }
    product.assemblies.push_back(std::move(root));
    product.root = 0;
    error.clear();
    return true;
}

} // namespace cadnext::gui
