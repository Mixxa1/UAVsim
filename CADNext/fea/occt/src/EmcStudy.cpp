#include "cadnext/fea/EmcStudy.hpp"

#include "cadnext/em/Fdtd.hpp"
#include "cadnext/fea/SolidMesher.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <unordered_map>

namespace cadnext::fea {

namespace {

using em::Axis;

// The most shielding this solver will claim. Beyond it the field inside is at the grid's own zero
// and the answer is "nothing measurable got through", not a number.
constexpr double kShieldingCeilingDb = 200.0;

Result<EmcStudyResult> failure(ErrorCode code, const std::string& message) {
    return Result<EmcStudyResult>::fail({code, message});
}

std::string format(double value, int digits) {
    char buffer[64];
    std::snprintf(buffer, sizeof(buffer), "%.*f", digits, value);
    return buffer;
}

StrengthVerdict worse(StrengthVerdict a, StrengthVerdict b) {
    return static_cast<int>(a) > static_cast<int>(b) ? a : b;
}

// The corner triangles of the mesh's boundary, in metres: what the voxeliser cuts the part out of.
void surfaceTriangles(const TetMesh& mesh, std::vector<std::array<double, 3>>& vertices, std::vector<std::array<int, 3>>& triangles) {
    std::unordered_map<int, int> index;
    auto vertex = [&](int node) {
        const auto found = index.find(node);
        if (found != index.end()) return found->second;
        const int created = static_cast<int>(vertices.size());
        vertices.push_back({mesh.nodes[node].x, mesh.nodes[node].y, mesh.nodes[node].z});
        index.emplace(node, created);
        return created;
    };
    for (const auto& [name, faces] : mesh.faceGroups) {
        (void)name;
        for (const auto& face : faces) {
            const auto nodes = mesh.faceNodes(face);
            triangles.push_back({vertex(nodes[0]), vertex(nodes[1]), vertex(nodes[2])});
        }
    }
}

struct Sweep {
    std::vector<std::vector<double>> shieldingDb; // [probe][frequency]
    std::vector<double> interiorVm;               // the worst probe's field, per frequency, per volt of incidence
    double stepS = 0.0;
    int steps = 0;
    std::size_t metalCells = 0;
    int nx = 0, ny = 0, nz = 0;
};

} // namespace

Result<EmcStudyResult> runEmcStudy(const kernel::OcctKernel& kernel, const kernel::ShapeHandle& shape, const IsotropicMaterial& material,
                                   const std::string& loadCaseName, const EmcStudySettings& settings, const StructuralStudyProgress& progress) {
    if (!(settings.coarseCellM > 0.0)) return failure(ErrorCode::InvalidArgument, "не задан шаг сетки FDTD");
    if (!(settings.refinementFactor >= 1.2)) return failure(ErrorCode::InvalidArgument, "измельчение должно быть не меньше 1.2");
    if (!(settings.lowHz > 0.0) || !(settings.highHz > settings.lowHz)) return failure(ErrorCode::InvalidArgument, "не задан диапазон частот");
    if (settings.points < 2) return failure(ErrorCode::InvalidArgument, "нужно не меньше двух частот в развёртке");
    if (settings.probes.empty()) return failure(ErrorCode::InvalidArgument, "не задано ни одной точки оборудования внутри корпуса");
    if (settings.incidence == settings.polarization) return failure(ErrorCode::InvalidArgument, "поляризация должна быть поперечной к направлению прихода волны");

    double fieldVm = settings.fieldVm;
    std::string levelDescription;
    if (!settings.levelId.empty()) {
        const auto* level = em::radiatedLevel(settings.levelId);
        if (level == nullptr) return failure(ErrorCode::NotFound, "нет данных: уровень «" + settings.levelId + "» отсутствует в таблицах");
        fieldVm = level->fieldVm;
        levelDescription = level->description;
        if (settings.lowHz < level->lowHz || settings.highHz > level->highHz) {
            return failure(ErrorCode::InvalidArgument, "развёртка выходит за диапазон уровня стандарта");
        }
    }
    if (!(fieldVm > 0.0)) return failure(ErrorCode::InvalidArgument, "не задана напряжённость поля: уровнем стандарта или числом");

    EmcStudyResult result;
    result.loadCaseName = loadCaseName;
    result.material = material;
    result.fieldVm = fieldVm;
    result.levelDescription = levelDescription;
    result.lowHz = settings.lowHz, result.highHz = settings.highHz;
    for (int p = 0; p < settings.points; ++p) {
        const double t = static_cast<double>(p) / (settings.points - 1);
        result.frequenciesHz.push_back(settings.lowHz * std::pow(settings.highHz / settings.lowHz, t));
    }

    // The part is triangulated once: the voxels of every level are cut from the same surface, so the
    // levels differ by the grid alone.
    SolidMeshingSettings meshing;
    meshing.maximumElementSizeM = settings.surfaceElementSizeM > 0.0 ? settings.surfaceElementSizeM : settings.coarseCellM;
    meshing.order = ElementOrder::Linear;
    const auto meshed = meshSolid(kernel, shape, meshing);
    if (!meshed.isOk()) return failure(meshed.error().code, meshed.error().message);
    const TetMesh& mesh = meshed.value().mesh;
    result.mesherVersion = meshed.value().mesherVersion;

    std::vector<std::array<double, 3>> vertices;
    std::vector<std::array<int, 3>> triangles;
    surfaceTriangles(mesh, vertices, triangles);
    if (triangles.empty()) return failure(ErrorCode::NotFound, "у детали нет поверхности");

    double minimum[3] = {1e300, 1e300, 1e300}, maximum[3] = {-1e300, -1e300, -1e300};
    for (const auto& v : vertices)
        for (int a = 0; a < 3; ++a) minimum[a] = std::min(minimum[a], v[a]), maximum[a] = std::max(maximum[a], v[a]);

    const int pad = std::max(settings.pmlCells, 4) + std::max(settings.marginCells, 2) + 2;
    auto runLevel = [&](double cell, bool wantSurface, double surfaceFrequency, Sweep& sweep, std::vector<double>* surfaceField) -> Result<int> {
        em::YeeGrid grid;
        grid.cellM = cell;
        grid.originX = minimum[0] - pad * cell;
        grid.originY = minimum[1] - pad * cell;
        grid.originZ = minimum[2] - pad * cell;
        grid.nx = static_cast<int>(std::ceil((maximum[0] - minimum[0]) / cell)) + 2 * pad;
        grid.ny = static_cast<int>(std::ceil((maximum[1] - minimum[1]) / cell)) + 2 * pad;
        grid.nz = static_cast<int>(std::ceil((maximum[2] - minimum[2]) / cell)) + 2 * pad;

        em::FdtdProblem problem;
        problem.grid = grid;
        problem.pmlCells = std::max(settings.pmlCells, 4);
        const auto cells = em::voxelizeSurface(grid, vertices, triangles);
        std::size_t metal = 0;
        for (std::uint8_t value : cells) metal += value;
        if (metal == 0) return Result<int>::fail({ErrorCode::InvalidArgument, "ни одна ячейка не попала внутрь детали: шаг сетки крупнее самой детали"});
        em::markMetalCells(grid, problem.pec, cells);
        sweep.metalCells = metal;
        sweep.nx = grid.nx, sweep.ny = grid.ny, sweep.nz = grid.nz;

        em::PlaneWaveSource wave;
        wave.propagation = settings.incidence;
        wave.forward = settings.forward;
        wave.polarization = settings.polarization;
        wave.marginCells = std::max(settings.marginCells, 2);
        const auto pulse = em::ricker(settings.lowHz, settings.highHz);
        wave.waveform = [pulse](double t) { return pulse(t); };
        problem.plane = wave;
        problem.recordHistory = false;
        problem.frequenciesHz = wantSurface ? std::vector<double>{surfaceFrequency} : result.frequenciesHz;

        // Probes: the equipment, or every node of the part's surface when the field is wanted.
        std::vector<std::array<double, 3>> points;
        if (wantSurface) {
            for (const auto& node : result.field.nodes) points.push_back({node.x, node.y, node.z});
        } else {
            for (const auto& probe : settings.probes) points.push_back({probe.x, probe.y, probe.z});
        }
        problem.probes = points;
        if (!wantSurface) {
            // Equipment has to be inside the box and in air, not in the metal.
            for (std::size_t p = 0; p < points.size(); ++p) {
                // The cell that holds the point, not the nearest node: half a cell either way is the
                // difference between the wall and the cavity behind it.
                const int ci = std::clamp(static_cast<int>(std::floor((points[p][0] - grid.originX) / cell)), 0, grid.nx - 1);
                const int cj = std::clamp(static_cast<int>(std::floor((points[p][1] - grid.originY) / cell)), 0, grid.ny - 1);
                const int ck = std::clamp(static_cast<int>(std::floor((points[p][2] - grid.originZ) / cell)), 0, grid.nz - 1);
                if (cells[(static_cast<std::size_t>(ci) * grid.ny + cj) * grid.nz + ck]) {
                    return Result<int>::fail({ErrorCode::InvalidArgument, "точка «" + settings.probes[p].name + "» попала в металл детали, а не в её полость"});
                }
            }
        }

        // Long enough for the wave to cross the box many times, and for the lowest frequency of the
        // sweep to have a few cycles inside the window.
        const double diagonal = std::sqrt(std::pow(maximum[0] - minimum[0], 2.0) + std::pow(maximum[1] - minimum[1], 2.0) + std::pow(maximum[2] - minimum[2], 2.0));
        const double step = grid.courantStepS(problem.courantFactor);
        const double duration = std::max(4.0 / settings.lowHz, 20.0 * diagonal / em::kSpeedOfLightMps);
        problem.steps = static_cast<int>(std::ceil(duration / step));
        sweep.stepS = step;
        sweep.steps = problem.steps;

        const auto run = em::solveFdtd(problem);
        if (!run.isOk()) return Result<int>::fail(run.error());
        if (wantSurface) {
            surfaceField->assign(points.size(), 0.0);
            const double incident = std::abs(run.value().incidentSpectrum[0]);
            for (std::size_t p = 0; p < points.size(); ++p) {
                const auto& s = run.value().probes[p].spectrum[0];
                const double magnitude = std::sqrt(std::norm(s[0]) + std::norm(s[1]) + std::norm(s[2]));
                (*surfaceField)[p] = incident > 0.0 ? fieldVm * magnitude / incident : 0.0;
            }
            return Result<int>::ok(0);
        }
        sweep.shieldingDb.assign(points.size(), std::vector<double>(result.frequenciesHz.size(), 0.0));
        sweep.interiorVm.assign(result.frequenciesHz.size(), 0.0);
        for (std::size_t f = 0; f < result.frequenciesHz.size(); ++f) {
            const double incident = std::abs(run.value().incidentSpectrum[f]);
            for (std::size_t p = 0; p < points.size(); ++p) {
                const auto& s = run.value().probes[p].spectrum[f];
                const double magnitude = std::sqrt(std::norm(s[0]) + std::norm(s[1]) + std::norm(s[2]));
                // A box the grid cannot see through gives machine zero inside, and no run of any
                // length can say more than that: the number is capped and called a lower bound.
                const double shielding = std::min(em::shieldingEffectivenessDb(incident, magnitude), kShieldingCeilingDb);
                sweep.shieldingDb[p][f] = shielding;
                sweep.interiorVm[f] = std::max(sweep.interiorVm[f], incident > 0.0 ? magnitude / incident : 0.0);
            }
        }
        return Result<int>::ok(0);
    };

    // --- Three grids.
    std::vector<Sweep> sweeps;
    for (int level = 0; level < 3; ++level) {
        if (progress) progress(level, "mesh");
        const double cell = settings.coarseCellM / std::pow(settings.refinementFactor, level);
        Sweep sweep;
        if (progress) progress(level, "solve");
        const auto ran = runLevel(cell, false, 0.0, sweep, nullptr);
        if (!ran.isOk()) return failure(ran.error().code, ran.error().message);
        EmcLevel record;
        record.cellM = cell;
        record.cells = sweep.metalCells;
        record.nx = sweep.nx, record.ny = sweep.ny, record.nz = sweep.nz;
        record.worstShieldingDb = std::numeric_limits<double>::infinity();
        for (std::size_t p = 0; p < sweep.shieldingDb.size(); ++p)
            for (std::size_t f = 0; f < sweep.shieldingDb[p].size(); ++f)
                if (sweep.shieldingDb[p][f] < record.worstShieldingDb) {
                    record.worstShieldingDb = sweep.shieldingDb[p][f];
                    record.worstFrequencyHz = result.frequenciesHz[f];
                }
        result.levels.push_back(record);
        sweeps.push_back(std::move(sweep));
    }

    const Sweep& finest = sweeps.back();
    result.stepS = finest.stepS;
    result.steps = finest.steps;
    result.worstShieldingDb = result.levels[2].worstShieldingDb;
    result.worstFrequencyHz = result.levels[2].worstFrequencyHz;
    const double r21 = result.levels[2].cellM > 0.0 ? result.levels[1].cellM / result.levels[2].cellM : 1.0;
    const double r32 = result.levels[1].cellM > 0.0 ? result.levels[0].cellM / result.levels[1].cellM : 1.0;
    result.shieldingConvergence = estimateConvergence(result.levels[2].worstShieldingDb, result.levels[1].worstShieldingDb, result.levels[0].worstShieldingDb,
                                                      r21, r32, 1.25, 2.0);
    result.shieldingUncertaintyDb = result.shieldingConvergence.isUsable()
                                        ? result.shieldingConvergence.uncertaintyAbsolute
                                        : std::max({result.levels[0].worstShieldingDb, result.levels[1].worstShieldingDb, result.levels[2].worstShieldingDb})
                                              - std::min({result.levels[0].worstShieldingDb, result.levels[1].worstShieldingDb, result.levels[2].worstShieldingDb});

    // --- What each piece of equipment sees.
    auto report = [&](StrengthVerdict verdict, const std::string& reason) {
        result.verdict = worse(result.verdict, verdict);
        (verdict == StrengthVerdict::Fail ? result.failureReasons : result.reasons).push_back(reason);
    };
    result.verdict = StrengthVerdict::Pass;
    for (std::size_t p = 0; p < settings.probes.size(); ++p) {
        EmcProbeResult record;
        record.name = settings.probes[p].name;
        record.immunityVm = settings.probes[p].immunityVm;
        record.shieldingDb = finest.shieldingDb[p];
        record.worstShieldingDb = std::numeric_limits<double>::infinity();
        for (std::size_t f = 0; f < record.shieldingDb.size(); ++f)
            if (record.shieldingDb[f] < record.worstShieldingDb) {
                record.worstShieldingDb = record.shieldingDb[f];
                record.worstFrequencyHz = result.frequenciesHz[f];
            }
        record.uncertaintyDb = result.shieldingUncertaintyDb;
        record.fieldVm = fieldVm / std::pow(10.0, record.worstShieldingDb / 20.0);
        const double worstCase = fieldVm / std::pow(10.0, (record.worstShieldingDb - record.uncertaintyDb) / 20.0);
        if (!(record.immunityVm > 0.0)) {
            record.outcome = "unknown";
            report(StrengthVerdict::Warning, record.name + ": нет данных о стойкости оборудования, сравнивать не с чем (поле "
                                                 + format(record.fieldVm, 2) + " В/м)");
        } else if (record.fieldVm > record.immunityVm) {
            record.outcome = "fail";
            report(StrengthVerdict::Fail, record.name + ": поле " + format(record.fieldVm, 2) + " В/м на " + format(record.worstFrequencyHz / 1e6, 1)
                                              + " МГц против предела " + format(record.immunityVm, 2) + " В/м");
        } else if (worstCase > record.immunityVm) {
            record.outcome = "warning";
            report(StrengthVerdict::Warning, record.name + ": поле " + format(record.fieldVm, 2) + " В/м, но в пределах погрешности сетки ("
                                                 + format(record.uncertaintyDb, 2) + " дБ) достаёт до предела " + format(record.immunityVm, 2) + " В/м");
        } else {
            record.outcome = "pass";
        }
        result.probes.push_back(std::move(record));
    }

    // --- Where the empty box rings: the shielding there is a lower bound, not a number.
    for (std::size_t f = 1; f + 1 < result.frequenciesHz.size(); ++f) {
        if (finest.interiorVm[f] > finest.interiorVm[f - 1] && finest.interiorVm[f] > finest.interiorVm[f + 1]) {
            result.resonancesHz.push_back(result.frequenciesHz[f]);
        }
    }

    // --- What the grid can and cannot say.
    const double cell = result.levels[2].cellM;
    result.cellsPerWavelength = em::kSpeedOfLightMps / settings.highHz / cell;
    const double voxelVolume = static_cast<double>(finest.metalCells) * cell * cell * cell;
    const double cadVolume = meshed.value().cadVolumeM3;
    result.wallCells = cadVolume > 0.0 ? voxelVolume / cadVolume : 0.0;
    if (result.cellsPerWavelength < 10.0) {
        report(StrengthVerdict::Warning, "на верхней частоте развёртки в длине волны меньше 10 ячеек — дисперсия сетки видна в результате");
    }
    if (cadVolume > 0.0 && std::fabs(voxelVolume / cadVolume - 1.0) > 0.05) {
        report(StrengthVerdict::Warning, "объём вокселей отличается от объёма детали на " + format(100.0 * (voxelVolume / cadVolume - 1.0), 1)
                                             + " % — стенки тоньше ячейки либо теряются, либо запаиваются, и щели вместе с ними");
    }
    if (result.worstShieldingDb >= kShieldingCeilingDb) {
        report(StrengthVerdict::Warning, "поле внутри — машинный нуль: сквозного пути в сетке нет, экранирование "
                                             + format(kShieldingCeilingDb, 0) + " дБ это оценка снизу, а не измерение");
    } else if (result.worstShieldingDb > -result.numericalFloorDb) {
        report(StrengthVerdict::Warning, "экранирование " + format(result.worstShieldingDb, 1) + " дБ выше численного пола решателя ("
                                             + format(-result.numericalFloorDb, 0) + " дБ): это оценка снизу, а не измерение");
    }
    result.warnings.push_back("корпус пуст и без потерь: на собственных частотах полости поле внутри ограничено только длиной счёта, "
                              "и экранирование там — нижняя оценка");
    result.warnings.push_back("металл идеальный, сквозь стенки не проходит ничего: результат определяют только отверстия, щели и стыки");
    result.warnings.push_back("волна приходит по оси под прямым углом; другие направления — другие расчёты");
    result.warnings.push_back("кабели и их связь с полем не моделируются (это CS114/CS116, а не RS103)");
    if (!result.resonancesHz.empty()) {
        std::string list;
        for (double frequency : result.resonancesHz) list += (list.empty() ? "" : ", ") + format(frequency / 1e6, 1);
        result.warnings.push_back("резонансы полости в развёртке: " + list + " МГц");
    }

    // --- The surface of the part, coloured by the field at the worst frequency.
    std::unordered_map<int, int> fieldIndex;
    auto fieldNode = [&](int meshNode) {
        const auto found = fieldIndex.find(meshNode);
        if (found != fieldIndex.end()) return found->second;
        const int index = static_cast<int>(result.field.nodes.size());
        result.field.nodes.push_back(mesh.nodes[meshNode]);
        result.field.displacement.push_back({});
        result.field.vonMisesPa.push_back(0.0);
        fieldIndex.emplace(meshNode, index);
        return index;
    };
    for (const auto& [name, faces] : mesh.faceGroups) {
        for (const auto& face : faces) {
            const auto nodes = mesh.faceNodes(face);
            std::vector<int> f;
            for (int node : nodes) f.push_back(fieldNode(node));
            if (f.size() >= 3) {
                result.field.triangles.push_back({f[0], f[1], f[2]});
                result.field.triangleFace.push_back(name);
            }
        }
    }
    Sweep surfaceSweep;
    const auto surfaceRun = runLevel(result.levels[2].cellM, true, result.worstFrequencyHz, surfaceSweep, &result.fieldEVm);
    if (!surfaceRun.isOk()) return failure(surfaceRun.error().code, surfaceRun.error().message);
    return Result<EmcStudyResult>::ok(std::move(result));
}

} // namespace cadnext::fea
